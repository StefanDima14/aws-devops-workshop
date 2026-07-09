"""
Simple Flask application for the AWS DevOps workshop.

It serves a single page that plays a video and exposes a /health endpoint used
by Docker healthchecks and (optionally) load balancers.

The video lives in a **private** S3 bucket. The app never exposes the bucket
publicly: on each page load it mints a short-lived *presigned* URL using the
EC2 instance's IAM role (no credentials are baked into the image). If no bucket
is configured it falls back to a public VIDEO_URL, so the app still runs locally
and in tests without any AWS access.
"""
import logging
import os
import socket

from flask import Flask, render_template, jsonify

logger = logging.getLogger(__name__)

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


@app.route("/")
def index():
    """Render the landing page that displays the video."""
    return render_template(
        "index.html",
        video_url=get_video_url(),
        version=APP_VERSION,
        hostname=socket.gethostname(),
    )


@app.route("/health")
def health():
    """Lightweight health endpoint for container / LB checks."""
    return jsonify(status="healthy", version=APP_VERSION), 200


if __name__ == "__main__":
    # 0.0.0.0 so the app is reachable from outside the container.
    # Port comes from env to stay flexible; defaults to 8080.
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
