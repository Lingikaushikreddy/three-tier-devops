"""gunicorn configuration — the other half of multiprocess metrics."""

import os
import shutil

bind = "0.0.0.0:8000"
workers = 2
accesslog = "-"

_multiproc_dir = os.environ.get("PROMETHEUS_MULTIPROC_DIR")


def on_starting(server):
    """Wipe stale metric files before the first worker starts.

    Those .db files survive a container restart if the directory is a volume.
    Left behind, they'd be summed into the totals and you'd see counters that
    look impossibly high after every restart.
    """
    if _multiproc_dir and os.path.isdir(_multiproc_dir):
        shutil.rmtree(_multiproc_dir, ignore_errors=True)
    if _multiproc_dir:
        os.makedirs(_multiproc_dir, exist_ok=True)


def child_exit(server, worker):
    """Required by prometheus_client: drop a dead worker's gauge files.

    Skip this and a crashed worker's numbers stay in the totals forever — you
    get phantom traffic from a process that no longer exists.
    """
    if _multiproc_dir:
        from prometheus_client import multiprocess

        multiprocess.mark_process_dead(worker.pid)
