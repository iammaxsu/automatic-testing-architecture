# function.py — shared helpers (counter, timing, logging setup)
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path

_COUNTER_FILE = "counter.log"


# ---------- Counter ----------

def read_count(path: str = _COUNTER_FILE) -> int:
    if os.path.exists(path):
        with open(path, "r") as f:
            val = f.read().strip()
            return int(val) if val.isdigit() else 0
    return 0


def write_count(count: int, path: str = _COUNTER_FILE) -> None:
    with open(path, "w") as f:
        f.write(str(count) + "\n")


def update_count(path: str = _COUNTER_FILE) -> int:
    count = read_count(path) + 1
    write_count(count, path)
    return count


def reset_count(path: str = _COUNTER_FILE) -> None:
    write_count(0, path)


# ---------- Timing ----------

def now_iso() -> str:
    """Current UTC time as ISO-8601 string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_ts() -> str:
    """Compact local timestamp for filenames: 20260528_100000."""
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def elapsed(start: float) -> float:
    """Seconds since start (from time.monotonic())."""
    return time.monotonic() - start


# ---------- Logging setup ----------

def setup_logging(log_path: str, level: int = logging.INFO) -> None:
    """Configure root logger to write to both console and file."""
    root = logging.getLogger()
    root.setLevel(level)

    fmt = logging.Formatter("%(asctime)s  %(levelname)-8s  %(name)s: %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")

    # Console handler
    ch = logging.StreamHandler()
    ch.setFormatter(fmt)
    root.addHandler(ch)

    # File handler
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setFormatter(fmt)
    root.addHandler(fh)


# ---------- JSON result writer ----------

def write_result_json(path: str, data: dict) -> None:
    """Atomically write result dict to path (write to .tmp then rename)."""
    tmp = path + ".tmp"
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
