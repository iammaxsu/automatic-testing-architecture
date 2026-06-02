# function.py — shared helpers (counter, timing, logging setup)
import json
import logging
import os
import time
from datetime import datetime
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
    """DUT-local time, ISO-8601 extended, no offset (LOG022): 2026-05-28T10:00:00.

    Used for JSON time fields and log content. Local time per LOG005/LOG022;
    the timezone is recorded once in the log header, not on every timestamp.
    """
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def now_ts() -> str:
    """DUT-local time, ISO-8601 basic, for filenames (LOG022): 20260528T100000.

    Basic format (no colons) is mandatory because ':' is illegal in Windows
    filenames. The 'T' separator distinguishes date from time.
    """
    return datetime.now().strftime("%Y%m%dT%H%M%S")


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


# ---------- JSON helpers ----------

def write_json(path: str, data: dict) -> None:
    """Atomically write dict to path (write to .tmp then rename)."""
    tmp = path + ".tmp"
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def read_json(path: str):
    """Return parsed JSON at path, or None if the file does not exist."""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return None


# Backwards-compatible alias (result.json is written via the same atomic path)
def write_result_json(path: str, data: dict) -> None:
    """Atomically write result dict to path (see write_json)."""
    write_json(path, data)
