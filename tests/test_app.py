"""Basic unit tests. In CI these run before we ever build the Docker image."""
import os
import sys

# Make the app importable (app/ lives next to tests/).
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import pytest  # noqa: E402
import app as app_module  # noqa: E402
from app import app as flask_app  # noqa: E402


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as client:
        yield client


def test_index_returns_200(client):
    """The landing page should load."""
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"<video" in resp.data


def test_health_returns_healthy(client):
    """Health endpoint must report healthy for LB/Docker checks."""
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "healthy"


def test_video_url_falls_back_without_bucket(monkeypatch):
    """With no S3 bucket configured, we use the public fallback URL."""
    monkeypatch.setattr(app_module, "VIDEO_BUCKET", "")
    assert app_module.get_video_url() == app_module.FALLBACK_VIDEO_URL


def test_video_url_presigns_when_bucket_set(monkeypatch):
    """With a bucket configured, we return a presigned S3 URL (no real AWS)."""
    monkeypatch.setattr(app_module, "VIDEO_BUCKET", "my-bucket")

    class FakeS3:
        def generate_presigned_url(self, op, Params, ExpiresIn):  # noqa: N803
            assert op == "get_object"
            assert Params["Bucket"] == "my-bucket"
            return "https://my-bucket.s3.amazonaws.com/video.mp4?X-Amz-Signature=abc"

    monkeypatch.setattr(app_module, "_get_s3_client", lambda: FakeS3())
    url = app_module.get_video_url()
    assert "X-Amz-Signature" in url


def test_video_url_falls_back_on_presign_error(monkeypatch):
    """A signing failure degrades gracefully to the fallback URL, never a 500."""
    monkeypatch.setattr(app_module, "VIDEO_BUCKET", "my-bucket")

    def boom():
        raise RuntimeError("no credentials")

    monkeypatch.setattr(app_module, "_get_s3_client", boom)
    assert app_module.get_video_url() == app_module.FALLBACK_VIDEO_URL


# --- Monitoring step ---------------------------------------------------------
def test_panel_page_loads(client):
    """The Ops Console page renders with its buttons."""
    resp = client.get("/panel")
    assert resp.status_code == 200
    assert b"Ops Console" in resp.data


def test_metrics_endpoint_exposes_prometheus(client):
    """/metrics serves Prometheus text including our custom series."""
    resp = client.get("/metrics")
    assert resp.status_code == 200
    # Both a default process metric and one of our load-generator gauges.
    assert b"app_memory_allocated_bytes" in resp.data
    assert b"app_cpu_workers" in resp.data


def test_load_state_reports_gauges(client):
    """The console polls /api/load/state; it must return the known keys."""
    resp = client.get("/api/load/state")
    assert resp.status_code == 200
    state = resp.get_json()["state"]
    for key in ("memory_mb", "cpu_workers", "disk_mb", "network_workers"):
        assert key in state


def test_unknown_load_action_is_rejected(client):
    """An unknown resource/action pair is a 400, not a 500."""
    resp = client.post("/api/load/teleporter/increase")
    assert resp.status_code == 400


def test_memory_button_actually_allocates(client):
    """Increasing then decreasing memory moves the gauge and nets to zero."""
    before = client.get("/api/load/state").get_json()["state"]["memory_blocks"]
    up = client.post("/api/load/memory/increase").get_json()["state"]
    assert up["memory_blocks"] == before + 1
    down = client.post("/api/load/memory/decrease").get_json()["state"]
    assert down["memory_blocks"] == before


def test_logs_endpoint_returns_recent_lines(client):
    """Every action logs; the in-app viewer can read those lines back."""
    client.post("/api/load/memory/increase")
    client.post("/api/load/memory/decrease")
    resp = client.get("/api/logs")
    assert resp.status_code == 200
    logs = resp.get_json()["logs"]
    assert any("Ops Console action" in entry["message"] for entry in logs)
