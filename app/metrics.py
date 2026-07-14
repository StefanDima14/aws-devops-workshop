"""
Prometheus metrics wiring.

Prometheus is *pull*-based: it periodically scrapes GET /metrics and stores what
it finds. This module defines the app-specific series and renders them in the
text exposition format Prometheus expects.

Three families of metrics reach the dashboard:

  1. **Defaults** — prometheus_client automatically registers process metrics
     (resident memory, CPU seconds, open FDs, ...). We get those for free.
  2. **Per-request** — the counter + histogram below, updated in app.py, give us
     request rate, error rate and latency percentiles.
  3. **Load generator** — the gauges/counter in loadgen.py, moved by the buttons.

All three share the default registry, so a single generate_latest() emits them.
"""
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

# Exported so app.py can set the Content-Type header on /metrics.
METRICS_CONTENT_TYPE = CONTENT_TYPE_LATEST

# Count every HTTP request, split by method, endpoint and status code. The
# `status` label is what lets Grafana chart a 5xx error rate.
REQUEST_COUNT = Counter(
    "app_http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)

# Latency as a histogram → Prometheus can compute p50/p95/p99 with histogram_quantile.
REQUEST_LATENCY = Histogram(
    "app_http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint"],
)


def render_metrics():
    """Serialise every registered metric in Prometheus' text format."""
    return generate_latest()
