"""
Load generator — the engine behind the "Ops Console" buttons.

This module makes the app *actually* consume resources so you can watch the
effect appear in Prometheus and Grafana. Nothing here is faked:

  * MEMORY  — we allocate real byte buffers and keep references to them, so the
              pages stay resident (the OS can't reclaim them).
  * CPU     — we start real worker *processes* that spin in a tight hashing loop.
              Processes (not threads) because Python's GIL means one busy thread
              only ever saturates a single core; separate processes let the load
              climb across all the cores the container is given.
  * DISK    — we write real files full of random bytes to a data directory, and
              a "cleanup" button deletes them again.
  * NETWORK — we start worker threads that repeatedly pull a payload over TCP,
              moving real bytes through the network stack.

Everything is driven through a single thread-safe :class:`LoadManager` so the
web layer never has to reason about locks. Each knob also updates a Prometheus
gauge/counter (defined at the bottom) so the dashboard can graph it.

Design note: the app is intentionally run with a *single* Gunicorn worker (see
docker-compose.yml). All of this state — the buffers, the process handles, the
metrics — lives in one process, so a button click always lands on the process
that owns the load. With multiple workers the state would be split across them
and the console would behave randomly.
"""
import logging
import multiprocessing
import os
import tempfile
import threading
import time
import uuid

from prometheus_client import Counter, Gauge

logger = logging.getLogger("app.loadgen")

# --- Tunables (12-factor: overridable via env, sane defaults for a laptop) ----
MEM_BLOCK_MB = int(os.environ.get("MEM_BLOCK_MB", "64"))        # RAM added per click
DISK_BLOCK_MB = int(os.environ.get("DISK_BLOCK_MB", "128"))     # file size per click
# Where "disk load" files live. In Docker this is a mounted volume (set via
# LOAD_DATA_DIR in docker-compose.yml); locally it defaults to a temp dir so the
# app and tests run anywhere without a read-only-filesystem surprise.
DATA_DIR = os.environ.get("LOAD_DATA_DIR", os.path.join(tempfile.gettempdir(), "workshop-loadgen"))
# URL a network worker hammers to move bytes. Defaults to the app talking to
# itself over the loopback interface, so the demo needs no internet access.
SELF_URL = os.environ.get("APP_SELF_URL", "http://127.0.0.1:8080")
NET_PAYLOAD_MB = int(os.environ.get("NET_PAYLOAD_MB", "4"))     # size of one fetch
MAX_CPU_WORKERS = int(os.environ.get("MAX_CPU_WORKERS", "16"))  # safety ceiling
MAX_MEM_BLOCKS = int(os.environ.get("MAX_MEM_BLOCKS", "64"))    # safety ceiling
MAX_NET_WORKERS = int(os.environ.get("MAX_NET_WORKERS", "16"))  # safety ceiling

_MB = 1024 * 1024


# --- Prometheus metrics -------------------------------------------------------
# These are the numbers the buttons move. The dashboard graphs exactly these.
MEM_BYTES = Gauge("app_memory_allocated_bytes", "Bytes deliberately allocated by the load generator")
CPU_WORKERS = Gauge("app_cpu_workers", "Number of CPU-burning worker processes")
DISK_BYTES = Gauge("app_disk_bytes", "Bytes written to disk by the load generator")
NET_WORKERS = Gauge("app_network_workers", "Number of active network worker threads")
NET_BYTES = Counter("app_network_bytes_total", "Total bytes pulled over the network by workers")


def _burn_cpu(stop_event):
    """Spin forever hashing numbers until asked to stop. Runs in its own process.

    Must be a top-level function so multiprocessing can pickle it on all
    platforms. The work itself is throwaway; the point is to keep a core busy.
    """
    import hashlib

    n = 0
    while not stop_event.is_set():
        hashlib.sha256(str(n).encode()).hexdigest()
        n += 1


class LoadManager:
    """Owns all deliberate load. Every public method is safe to call from any
    request thread; a single lock serialises the mutations."""

    def __init__(self):
        self._lock = threading.Lock()
        self._mem_blocks = []          # list[bytearray] — kept alive on purpose
        self._cpu_procs = []           # list[(Process, Event)]
        self._net_stop = threading.Event()
        self._net_threads = []         # list[threading.Thread]
        os.makedirs(DATA_DIR, exist_ok=True)
        # Reflect any files left over from a previous run in the gauge.
        DISK_BYTES.set(self._disk_usage_bytes())

    # -- Memory ---------------------------------------------------------------
    def add_memory(self):
        """Allocate one more block of real, resident memory."""
        with self._lock:
            if len(self._mem_blocks) >= MAX_MEM_BLOCKS:
                logger.warning("Memory ceiling reached (%d blocks); ignoring", MAX_MEM_BLOCKS)
                return
            # bytearray(n) zero-fills, which touches every page so it actually
            # counts against RSS instead of being lazily reserved.
            self._mem_blocks.append(bytearray(MEM_BLOCK_MB * _MB))
            MEM_BYTES.set(len(self._mem_blocks) * MEM_BLOCK_MB * _MB)
            logger.info("Allocated %d MB (total %d MB held)", MEM_BLOCK_MB, len(self._mem_blocks) * MEM_BLOCK_MB)

    def drop_memory(self):
        """Release one block so the OS can reclaim it."""
        with self._lock:
            if self._mem_blocks:
                self._mem_blocks.pop()
                MEM_BYTES.set(len(self._mem_blocks) * MEM_BLOCK_MB * _MB)
                logger.info("Freed %d MB (total %d MB held)", MEM_BLOCK_MB, len(self._mem_blocks) * MEM_BLOCK_MB)
            else:
                logger.info("No memory blocks to free")

    # -- CPU ------------------------------------------------------------------
    def add_cpu(self):
        """Start one more CPU-burning process (roughly one core of load)."""
        with self._lock:
            if len(self._cpu_procs) >= MAX_CPU_WORKERS:
                logger.warning("CPU ceiling reached (%d workers); ignoring", MAX_CPU_WORKERS)
                return
            stop = multiprocessing.Event()
            proc = multiprocessing.Process(target=_burn_cpu, args=(stop,), daemon=True)
            proc.start()
            self._cpu_procs.append((proc, stop))
            CPU_WORKERS.set(len(self._cpu_procs))
            logger.info("Started CPU worker pid=%s (%d running)", proc.pid, len(self._cpu_procs))

    def drop_cpu(self):
        """Stop one CPU-burning process."""
        with self._lock:
            if self._cpu_procs:
                proc, stop = self._cpu_procs.pop()
                stop.set()
                proc.join(timeout=2)
                if proc.is_alive():
                    proc.terminate()
                CPU_WORKERS.set(len(self._cpu_procs))
                logger.info("Stopped CPU worker pid=%s (%d running)", proc.pid, len(self._cpu_procs))
            else:
                logger.info("No CPU workers to stop")

    # -- Disk -----------------------------------------------------------------
    def add_disk(self):
        """Write one more file of random bytes to the data directory."""
        with self._lock:
            path = os.path.join(DATA_DIR, f"blob-{uuid.uuid4().hex}.bin")
            # Write in 1 MB chunks so we never hold the whole file in memory.
            with open(path, "wb") as fh:
                for _ in range(DISK_BLOCK_MB):
                    fh.write(os.urandom(_MB))
                fh.flush()
                os.fsync(fh.fileno())  # force it to the disk, not just the page cache
            DISK_BYTES.set(self._disk_usage_bytes())
            logger.info("Wrote %d MB to %s (total %d MB on disk)", DISK_BLOCK_MB, path, self._disk_usage_bytes() // _MB)

    def cleanup_disk(self):
        """Delete every file the load generator wrote."""
        with self._lock:
            removed = 0
            for name in os.listdir(DATA_DIR):
                try:
                    os.remove(os.path.join(DATA_DIR, name))
                    removed += 1
                except OSError:
                    logger.exception("Could not remove %s", name)
            DISK_BYTES.set(self._disk_usage_bytes())
            logger.info("Cleaned up %d file(s); %d MB left on disk", removed, self._disk_usage_bytes() // _MB)

    def _disk_usage_bytes(self):
        total = 0
        for name in os.listdir(DATA_DIR):
            try:
                total += os.path.getsize(os.path.join(DATA_DIR, name))
            except OSError:
                pass
        return total

    # -- Network --------------------------------------------------------------
    def add_network(self):
        """Start one more thread that continuously pulls a payload over TCP."""
        with self._lock:
            if len(self._net_threads) >= MAX_NET_WORKERS:
                logger.warning("Network ceiling reached (%d workers); ignoring", MAX_NET_WORKERS)
                return
            self._net_stop.clear()
            thread = threading.Thread(target=self._network_worker, daemon=True)
            thread.start()
            self._net_threads.append(thread)
            NET_WORKERS.set(len(self._net_threads))
            logger.info("Started network worker (%d running)", len(self._net_threads))

    def drop_network(self):
        """Stop one network worker (they all share one stop signal, so we just
        signal-all then let a single thread notice and exit)."""
        with self._lock:
            if not self._net_threads:
                logger.info("No network workers to stop")
                return
            # Signal every worker to exit its loop, then re-launch the ones we
            # want to keep. Simple and race-free for a demo-sized pool.
            self._net_stop.set()
            for thread in self._net_threads:
                thread.join(timeout=2)
            keep = len(self._net_threads) - 1
            self._net_threads = []
            NET_WORKERS.set(0)
        for _ in range(keep):
            self.add_network()
        logger.info("Stopped a network worker (%d running)", keep)

    def _network_worker(self):
        """Pull the payload endpoint in a loop, counting the bytes we move."""
        import requests  # imported lazily so tests/local runs need not install it eagerly

        url = f"{SELF_URL}/api/loadgen/payload"
        while not self._net_stop.is_set():
            try:
                with requests.get(url, stream=True, timeout=10) as resp:
                    for chunk in resp.iter_content(chunk_size=64 * 1024):
                        if self._net_stop.is_set():
                            break
                        NET_BYTES.inc(len(chunk))
            except Exception:  # noqa: BLE001 - a transient network hiccup shouldn't kill the worker
                logger.exception("Network worker error; retrying")
                time.sleep(1)

    # -- Introspection --------------------------------------------------------
    def state(self):
        """Return a plain dict the Ops Console renders as live gauges."""
        with self._lock:
            return {
                "memory_mb": len(self._mem_blocks) * MEM_BLOCK_MB,
                "memory_blocks": len(self._mem_blocks),
                "cpu_workers": len(self._cpu_procs),
                "disk_mb": self._disk_usage_bytes() // _MB,
                "network_workers": len(self._net_threads),
                # Echo the step sizes so the UI can label the buttons accurately.
                "mem_block_mb": MEM_BLOCK_MB,
                "disk_block_mb": DISK_BLOCK_MB,
            }


# One shared manager for the whole process.
manager = LoadManager()

# A fixed payload the network workers pull. Built once, reused forever.
NETWORK_PAYLOAD = os.urandom(NET_PAYLOAD_MB * _MB)
