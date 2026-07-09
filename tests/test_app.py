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
