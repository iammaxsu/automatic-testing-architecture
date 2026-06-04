# function.py — shared helpers (counter, timing, logging setup)
import json
import logging
import os
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

_COUNTER_FILE = "counter.log"


# ---------- DUT OS detection ----------

def detect_dut_os(host: str, port: int, ssh_user: str, timeout: int = 10) -> str:
    """Probe the DUT via SSH to determine its OS.

    Sends 'uname -s':
      Linux  → exits 0, stdout contains "Linux"  → returns "linux"
      Windows cmd.exe / PowerShell → uname not found, exit ≠ 0 → returns "windows"

    Returns "linux", "windows", or "unknown" (SSH unreachable or unexpected output).
    Never raises.
    """
    log = logging.getLogger("function")
    cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={timeout}",
        "-p", str(port),
        f"{ssh_user}@{host}",
        "uname -s",
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout + 5
        )
        if result.returncode == 0 and "Linux" in result.stdout:
            log.info("DUT OS detected: linux (uname -s → %s)", result.stdout.strip())
            return "linux"
        log.info("DUT OS detected: windows (uname -s exit %d)", result.returncode)
        return "windows"
    except Exception as exc:
        log.warning("DUT OS detection failed: %s — using config default", exc)
        return "unknown"


# ---------- DUT initialisation (FWK031) ----------

def init_dut(
    checker,                       # LivenessChecker | None
    relay,                         # RelayController | None
    power_type: str = "ATX",       # "ATX" or "AT"
    *,
    boot_timeout: float = 120,
    off_time: float = 60,
    short_press_sec: float = 0.5,
    force_off_sec: float = 5.0,
    init_wait: float = 0,
    dry_run: bool = False,
) -> tuple:
    """Bring the DUT to a testable (alive) state before a test begins (FWK031).

    Escalation chain — stops at the first step that leaves the DUT responding:

      Step 1  is_up() (ping OR SSH)        → already responding → done.
      Step 2  GPIO power-on press          → handles "DUT is OFF" (common after
                                             power_cycle, which ends powered off).
      Step 3  GPIO force-off + power-on     → handles "DUT is HUNG, not just off".
              (force-off → wait off_time → power-on)

    No SSH is used here: a DUT that fails Step 1 responds to neither ping nor
    SSH, so an SSH reboot could not work. Recovery is purely via GPIO/relay.

    When no relay is available (relay is None — GPIO pin unset), the only
    remedy is to wait up to init_wait seconds for a DUT that is powered but
    still booting (BIOS/POST). init_wait == 0 means fail immediately.

    Returns (ok, method) where method is one of:
      "no-check", "dry-run", "already-up", "wait", "power-on", "power-cycle",
      "no-relay", "failed-wait", "dead".
    """
    log = logging.getLogger("function")

    if dry_run:
        log.info("init_dut: [DRY-RUN] skipping DUT state check/recovery")
        return True, "dry-run"

    if checker is None:
        log.info("init_dut: liveness checks disabled — assuming DUT is ready")
        return True, "no-check"

    # ── Step 1: is the DUT already responding? ────────────────────────────────
    log.info("init_dut: checking whether DUT is already up (ping OR SSH) ...")
    if checker.is_up():
        log.info("init_dut: DUT is responding — already in a testable state")
        return True, "already-up"

    # DUT responds to neither ping nor SSH: it is off or hung.
    if relay is None:
        if init_wait > 0:
            log.info("init_dut: DUT offline and no relay configured — waiting up to "
                     "%ds in case it is still booting ...", init_wait)
            ok, _ = checker.wait_until_alive(init_wait)
            if ok:
                log.info("init_dut: DUT came online while waiting")
                return True, "wait"
            log.error("init_dut: DUT still offline after %ds and no relay to recover it",
                      init_wait)
            return False, "failed-wait"
        log.error("init_dut: DUT offline, no relay configured (GPIO pin unset), and "
                  "init_wait is 0 — cannot recover.")
        return False, "no-relay"

    # ── Step 2: gentle — power-on press (DUT is OFF) ──────────────────────────
    log.info("init_dut: DUT offline — issuing power-on (%s) ...", power_type)
    if power_type == "ATX":
        relay.atx_press(short_press_sec)
    else:
        relay.at_power_on()
    ok, t = checker.wait_until_alive(boot_timeout)
    if ok:
        log.info("init_dut: DUT came up %.1fs after power-on press", t)
        return True, "power-on"

    # ── Step 3: hard — force a full power cycle (DUT is HUNG) ─────────────────
    log.warning("init_dut: DUT still offline after power-on — forcing a full power cycle")
    if power_type == "ATX":
        relay.atx_force_off(force_off_sec)
    else:
        relay.at_power_off()
    time.sleep(off_time)
    if power_type == "ATX":
        relay.atx_press(short_press_sec)
    else:
        relay.at_power_on()
    ok, t = checker.wait_until_alive(boot_timeout)
    if ok:
        log.info("init_dut: DUT came up %.1fs after forced power cycle", t)
        return True, "power-cycle"

    log.error("init_dut: DUT did not come up after a forced power cycle — DUT may be dead")
    return False, "dead"



# ---------- DUT notification ----------

def notify_dut(
    ssh_user: str,
    host: str,
    port: int,
    message: str,
    ssh_timeout: int = 5,
    dry_run: bool = False,
    max_wait: int = 60,
    retry_interval: float = 10.0,
) -> None:
    """Send a msg.exe popup to the DUT's interactive desktop after boot.

    Runs in a background daemon thread so the test cycle is never blocked.
    Before sending msg.exe, polls 'query session' until an Active desktop
    session exists (up to max_wait seconds).  This handles the race where
    sshd starts before the interactive logon session is ready.

    Fails silently throughout — msg.exe may be absent (Windows Home) or
    no user may be logged in.
    """
    if dry_run or not ssh_user or not host:
        return

    def _worker():
        log = logging.getLogger("function")

        def _ssh(cmd):
            try:
                r = subprocess.run(
                    [
                        "ssh",
                        "-o", "StrictHostKeyChecking=no",
                        "-o", "BatchMode=yes",
                        "-o", f"ConnectTimeout={ssh_timeout}",
                        "-p", str(port),
                        f"{ssh_user}@{host}",
                        cmd,
                    ],
                    timeout=ssh_timeout + 2,
                    capture_output=True,
                    text=True,
                )
                return r.returncode, r.stdout
            except Exception as exc:
                log.debug("notify_dut SSH error: %s", exc)
                return -1, ""

        deadline = time.monotonic() + max_wait
        attempt = 0
        while time.monotonic() < deadline:
            rc, out = _ssh("query session")
            if rc == 0 and "Active" in out:
                _ssh(f"msg * {message}")
                log.debug("notify_dut: msg sent (attempt %d)", attempt + 1)
                return
            attempt += 1
            log.debug("notify_dut: no Active session yet (attempt %d), retry in %.0fs",
                      attempt, retry_interval)
            time.sleep(min(retry_interval, deadline - time.monotonic()))

        log.debug("notify_dut: no Active session within %ds — skipping", max_wait)

    threading.Thread(target=_worker, daemon=True, name="notify-dut").start()


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
