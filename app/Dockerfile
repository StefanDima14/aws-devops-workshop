# ---- Build a small, secure image ----
# Slim base keeps the image small and reduces the attack surface (fewer
# packages = fewer CVEs for Trivy to find).
FROM python:3.12-slim

# Don't buffer stdout/stderr so logs show up immediately in CloudWatch/docker logs.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

WORKDIR /app

# Install deps first so this layer is cached when only app code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code.
COPY . .

# Security best practice: run as a non-root user, never as root.
RUN useradd --create-home --shell /bin/bash appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

# Container-level healthcheck hitting our /health endpoint.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

# Gunicorn is a production WSGI server (Flask's dev server is not for prod).
# 2 workers is plenty for a t3.micro demo box.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
