"""
Simple Flask application for the AWS DevOps workshop.

It serves a single page that plays a video and exposes a /health endpoint used
by Docker healthchecks and (optionally) load balancers.

The video lives in a **private** S3 bucket. The app never exposes the bucket
publicly: on each page load it mints a short-lived *presigned* URL using the
EC2 instance's IAM role (no credentials are baked into the image). If no bucket
is configured it falls back to a public VIDEO_URL, so the app still runs locally
and in tests without any AWS access.

**Monitoring step.** This version also ships an "Ops Console" (/panel): a set of
buttons that make the app *really* consume RAM, CPU, disk and network so you can
watch the effect land in Prometheus + Grafana. Every request and every knob is
exported at /metrics, and logs stream both to stdout (→ Loki) and to an in-app
viewer. See loadgen.py, metrics.py and logbuffer.py for the details.
"""
import logging
import os
import socket
import time

from flask import Flask, Response, render_template, jsonify

from loadgen import manager, NETWORK_PAYLOAD
from logbuffer import ring_handler
from metrics import (
    REQUEST_COUNT,
    REQUEST_LATENCY,
    render_metrics,
    METRICS_CONTENT_TYPE,
)

# --- Logging ------------------------------------------------------------------
# One format for everyone. Records fan out to stdout (scraped by Promtail → Loki)
# and to the in-memory ring buffer (served at /api/logs for the in-app viewer).
_LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
logging.basicConfig(
    level=_LOG_LEVEL,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
# Set the level explicitly too: basicConfig is a no-op if the root logger already
# has handlers (e.g. under pytest or gunicorn), and then our INFO logs would be
# filtered out. Setting it directly guarantees the ring buffer sees them.
logging.getLogger().setLevel(_LOG_LEVEL)
logging.getLogger().addHandler(ring_handler)
logger = logging.getLogger("app")

app = Flask(__name__)

# --- Configuration -----------------------------------------------------------
# 12-factor: everything is injected via env so one image serves every
# environment without rebuilding (build once, configure per environment).
VIDEO_BUCKET = os.environ.get("VIDEO_BUCKET", "")
VIDEO_OBJECT_KEY = os.environ.get("VIDEO_OBJECT_KEY", "video.mp4")
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-1")
PRESIGN_EXPIRY = int(os.environ.get("PRESIGN_EXPIRY", "3600"))

# Fallback for local dev / tests / when no bucket is configured.
FALLBACK_VIDEO_URL = os.environ.get(
    "VIDEO_URL",
    "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4",
)
APP_VERSION = os.environ.get("APP_VERSION", "dev")

# Lazily-created boto3 S3 client (only built when a bucket is configured so
# local/test runs need neither boto3 credentials nor network access).
_s3_client = None


def _get_s3_client():
    global _s3_client
    if _s3_client is None:
        import boto3  # imported lazily; see note above

        _s3_client = boto3.client("s3", region_name=AWS_REGION)
    return _s3_client


def get_video_url():
    """Return a URL the browser can use to play the video.

    Prefers a short-lived presigned URL to the private S3 object; falls back to
    FALLBACK_VIDEO_URL when no bucket is configured or presigning fails (a
    signing hiccup should never turn into a 500 for the viewer).
    """
    if not VIDEO_BUCKET:
        return FALLBACK_VIDEO_URL
    try:
        return _get_s3_client().generate_presigned_url(
            "get_object",
            Params={"Bucket": VIDEO_BUCKET, "Key": VIDEO_OBJECT_KEY},
            ExpiresIn=PRESIGN_EXPIRY,
        )
    except Exception:  # noqa: BLE001 - degrade gracefully to the fallback URL
        logger.exception("Could not presign S3 video URL; using fallback")
        return FALLBACK_VIDEO_URL


# --- Request instrumentation -------------------------------------------------
# Time every request and count it by method/endpoint/status so Grafana can chart
# request rate and latency. We stash the start time on Flask's per-request `g`.
@app.before_request
def _start_timer():
    from flask import g

    g._start = time.perf_counter()


@app.after_request
def _record_metrics(response):
    from flask import g, request

    # Don't let the metrics endpoint measure itself into a feedback loop.
    endpoint = request.endpoint or "unknown"
    if endpoint != "metrics":
        elapsed = time.perf_counter() - getattr(g, "_start", time.perf_counter())
        REQUEST_LATENCY.labels(request.method, endpoint).observe(elapsed)
        REQUEST_COUNT.labels(request.method, endpoint, response.status_code).inc()
    return response


# --- Pages -------------------------------------------------------------------
@app.route("/")
def index():
    """Render the landing page that displays the video."""
    return render_template(
        "index.html",
        video_url=get_video_url(),
        version=APP_VERSION,
        hostname=socket.gethostname(),
    )


@app.route("/panel")
def panel():
    """The Ops Console: buttons that generate real load + a live log viewer."""
    return render_template(
        "panel.html",
        version=APP_VERSION,
        hostname=socket.gethostname(),
    )


@app.route("/health")
def health():
    """Lightweight health endpoint for container / LB checks."""
    return jsonify(status="healthy", version=APP_VERSION), 200


# --- Observability endpoints -------------------------------------------------
@app.route("/metrics")
def metrics():
    """Prometheus scrape target. Exposes default process metrics, per-request
    counters/histograms, and the load-generator gauges from loadgen.py."""
    return Response(render_metrics(), mimetype=METRICS_CONTENT_TYPE)


@app.route("/api/logs")
def api_logs():
    """Recent log lines for the in-app viewer (also shipped to Loki via stdout)."""
    from flask import request

    limit = min(int(request.args.get("limit", 200)), 500)
    return jsonify(logs=ring_handler.records(limit))


# --- Ops Console API ---------------------------------------------------------
# Each button POSTs here; the handler drives loadgen.manager and returns the
# fresh state so the UI can re-render its gauges. Actions are logged, which is
# how you get "log-emitting buttons" for free.
_ACTIONS = {
    ("memory", "increase"): manager.add_memory,
    ("memory", "decrease"): manager.drop_memory,
    ("cpu", "increase"): manager.add_cpu,
    ("cpu", "decrease"): manager.drop_cpu,
    ("disk", "increase"): manager.add_disk,
    ("disk", "cleanup"): manager.cleanup_disk,
    ("network", "increase"): manager.add_network,
    ("network", "decrease"): manager.drop_network,
}


@app.route("/api/load/<resource>/<action>", methods=["POST"])
def load_action(resource, action):
    """Apply one load action (e.g. /api/load/memory/increase)."""
    handler = _ACTIONS.get((resource, action))
    if handler is None:
        logger.warning("Rejected unknown load action: %s/%s", resource, action)
        return jsonify(error=f"unknown action {resource}/{action}"), 400
    logger.info("Ops Console action: %s/%s", resource, action)
    handler()
    return jsonify(state=manager.state())


@app.route("/api/load/state")
def load_state():
    """Current load levels, polled by the Ops Console to keep gauges live."""
    return jsonify(state=manager.state())


@app.route("/api/loadgen/payload")
def loadgen_payload():
    """A fixed blob the network workers pull to move real bytes. Internal use;
    it's what makes the 'increase network' button actually push traffic."""
    return Response(NETWORK_PAYLOAD, mimetype="application/octet-stream")


if __name__ == "__main__":
    # 0.0.0.0 so the app is reachable from outside the container.
    # Port comes from env to stay flexible; defaults to 8080.
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
