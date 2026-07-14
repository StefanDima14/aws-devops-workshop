"""
In-memory log ring buffer — powers the "Logs" viewer inside the Ops Console.

Logs go to two places at once:

  * **stdout** (via the normal logging handlers) — this is what Promtail scrapes
    and ships to Loki, so the same lines show up in Grafana.
  * **an in-process ring buffer** (this module) — the last N records, served as
    JSON at /api/logs so the app itself can show a live tail without any extra
    infrastructure.

Keeping the buffer small and bounded (a deque with maxlen) means it can never
leak memory no matter how chatty the app gets.
"""
import logging
import threading
from collections import deque

# How many recent records to keep for the in-app viewer.
RING_SIZE = 500


class RingBufferHandler(logging.Handler):
    """A logging handler that remembers the most recent records in memory."""

    def __init__(self, capacity=RING_SIZE):
        super().__init__()
        self._buffer = deque(maxlen=capacity)
        self._lock = threading.Lock()

    def emit(self, record):
        # format() turns the record into the same string that hits stdout.
        entry = {
            "time": self.format_time(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        with self._lock:
            self._buffer.append(entry)

    @staticmethod
    def format_time(record):
        # ISO-ish, second precision — enough for a human tailing the log.
        import time

        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(record.created))

    def records(self, limit=200):
        """Return up to ``limit`` most recent records, oldest first."""
        with self._lock:
            items = list(self._buffer)
        return items[-limit:]


# One shared handler instance, attached to the root logger in app.py.
ring_handler = RingBufferHandler()
