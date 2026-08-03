# function.py — shared helpers (counter, timing, logging setup)
import base64
import json
import logging
import os
import re
import ssl
import subprocess
import threading
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Optional

import config

# Anchored to the script directory, not the process working directory, for the
# same reason as config.LOG_DIR (LOG001/BUG0042): a bare "counter.log" follows
# whatever directory the operator launched from.
_COUNTER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "counter.log")


# ---------- SSH connection options (FWK035) ----------

def ssh_base_opts(connect_timeout: int = 10) -> list:
    """Standard ssh(1) options for every framework connection to a DUT.

    Returns the option list that sits between the `ssh` executable and the
    `user@host` target, so call sites build their command as:

        ["ssh", *ssh_base_opts(timeout), "-p", str(port), f"{user}@{host}", cmd]

    Centralising this list is the single source of truth that stops the six
    SSH call sites from drifting apart (the drift that caused BUG0033).

    The two host-key options are the important part (BUG0033):

      StrictHostKeyChecking=no      accepts an *unknown* host without prompting.
      UserKnownHostsFile=/dev/null  never reads or writes a known_hosts entry,
        so a DUT whose host key has *changed* (reimaged, OpenSSH reinstalled,
        OS swapped between Windows and Linux on the same IP) is accepted too.
        StrictHostKeyChecking=no ALONE does NOT override a changed-key
        rejection — OpenSSH still hard-refuses with "REMOTE HOST IDENTIFICATION
        HAS CHANGED" and a non-zero exit — which silently broke every SSH cycle
        once a lab DUT's key drifted. Lab DUTs are physically controlled, so
        skipping host-key trust carries no real man-in-the-middle risk here.

      LogLevel=ERROR   suppresses the multi-line changed-key warning banner so
        it never pollutes the test log (it does not hide the remote command's
        own stdout, so `uname -s` / `query session` probes still work).
      BatchMode=yes    never fall back to an interactive password prompt.
    """
    return [
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={connect_timeout}",
    ]


# ---------- DUT OS detection ----------

def detect_dut_os(host: str, port: int, ssh_user: str, timeout: int = 10) -> str:
    """Probe the DUT via SSH to determine its OS.

    Sends 'uname -s':
      Linux  → exits 0, stdout contains "Linux"  → returns "linux"
      Windows cmd.exe / PowerShell → uname not found, exit 1  → returns "windows"
      SSH unreachable (exit 255, timeout, exception)           → returns "unknown"

    Exit 255 means the SSH layer itself failed (connection refused, host offline)
    and says nothing about the OS — treated as "unknown", not "windows".

    Returns "linux", "windows", or "unknown". Never raises.
    """
    log = logging.getLogger("function")
    cmd = [
        "ssh",
        *ssh_base_opts(timeout),
        "-p", str(port),
        f"{ssh_user}@{host}",
        "uname -s",
    ]
    try:
        # errors="replace": a non-English Windows DUT (e.g. zh-TW) emits its
        # 'uname not recognized' error in the OEM code page (CP950/Big5), which
        # is not valid UTF-8.  Without this, the default strict decode raises
        # UnicodeDecodeError, the probe returns "unknown", and the OS falls back
        # to the linux default — sending 'sudo shutdown' to a Windows box (BUG0030).
        result = subprocess.run(
            cmd, capture_output=True, text=True, errors="replace",
            timeout=timeout + 5
        )
        if result.returncode == 0 and "Linux" in result.stdout:
            log.info("DUT OS detected: linux (uname -s → %s)", result.stdout.strip())
            return "linux"
        if result.returncode == 255:
            # SSH transport failure (connection refused, host unreachable, auth failure
            # in BatchMode).  This tells us nothing about the OS.
            log.warning("DUT OS detection: SSH failed (exit 255, host offline?) — unknown")
            return "unknown"
        log.info("DUT OS detected: windows (uname -s exit %d)", result.returncode)
        return "windows"
    except Exception as exc:
        log.warning("DUT OS detection failed: %s — using config default", exc)
        return "unknown"


def _ssh_probe_output(host: str, port: int, ssh_user: str, cmd: str, timeout: int) -> Optional[str]:
    """Run cmd on the DUT over SSH, return raw stdout on exit 0, else None.
    Never raises (PWR015)."""
    try:
        result = subprocess.run(
            ["ssh", *ssh_base_opts(timeout), "-p", str(port), f"{ssh_user}@{host}", cmd],
            capture_output=True, text=True, errors="replace", timeout=timeout + 5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout
        return None
    except Exception:
        return None


def _redfish_firmware_version(bmc_host: str, bmc_user: str, bmc_pass: str, timeout: int) -> Optional[str]:
    """Read FirmwareVersion from the BMC's own Redfish Manager resource.

    Talks directly to the BMC's management IP (bmc_host) over HTTPS — independent
    of the DUT's OS/SSH, since the BMC has its own network interface. Lab BMCs
    almost never carry a trusted certificate, so the cert is not verified (this is
    the management network, not a public one). Tries the common Manager resource
    ids since vendors disagree on naming. Never raises; returns None on any
    failure (PWR015)."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    headers = {"Accept": "application/json"}
    if bmc_user:
        token = base64.b64encode(f"{bmc_user}:{bmc_pass or ''}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"
    for manager_id in ("Self", "1", "BMC"):
        url = f"https://{bmc_host}/redfish/v1/Managers/{manager_id}"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="replace"))
                ver = data.get("FirmwareVersion")
                if ver:
                    return str(ver)
        except Exception:
            continue
    return None


def detect_firmware(
    host: str, port: int, ssh_user: str, dut_os: str, *,
    bmc_host: str = "", bmc_user: str = "", bmc_pass: str = "",
    timeout: int = 15, dry_run: bool = False,
) -> dict:
    """Probe BIOS and BMC firmware versions for result.json / the rendered
    report (PWR015).

    BIOS version (requires SSH; OS-specific command):
      linux:   sudo dmidecode -s bios-version
      windows: PowerShell (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion

    BMC version, tried in order, stopping at the first success:
      1. In-band over the same SSH session, using the OS-native IPMI tool:
           linux:   sudo ipmitool mc info   ("Firmware Revision" line)
           windows: ipmiutil health         ("BMC version" token)
         (ipmitool has no clean official Windows binary; ipmiutil does, so
         setup_dut.ps1 installs ipmiutil on Windows.) Works as long as the
         tool and the IPMI KCS driver are installed on the DUT.
      2. Redfish against bmc_host's own management IP — independent of DUT
         SSH/OS, so it also works when no in-band tool is installed. Skipped
         entirely when bmc_host is not given.
    A product with no BMC is expected to fail both, yielding "N/A" rather
    than a false detection.

    Never raises. dry_run=True returns fixed placeholder values without
    touching the network, matching every other SSH/network helper here.
    Returns {"bios_version": str, "bmc_version": str, "bmc_method": str|None}.
    """
    if dry_run:
        return {
            "bios_version": "DRY-RUN-BIOS-1.0",
            "bmc_version":  "DRY-RUN-BMC-1.0",
            "bmc_method":   "dry-run",
        }

    bios_version = None
    bmc_version  = None
    bmc_method   = None

    if ssh_user and host:
        bios_cmd = (
            'powershell -NoProfile -Command '
            '"(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion"'
            if dut_os == "windows" else
            "sudo dmidecode -s bios-version"
        )
        out = _ssh_probe_output(host, port, ssh_user, bios_cmd, timeout)
        if out:
            for line in out.splitlines():
                line = line.strip()
                if line:
                    bios_version = line
                    break

        if dut_os == "windows":
            # Windows in-band uses ipmiutil — ipmitool has no clean official
            # Windows binary, whereas ipmiutil ships a proper installer (the one
            # setup_dut.ps1 installs). `ipmiutil health` prints a line like:
            #   -- BMC version 1.40, IPMI version 2.0
            out = _ssh_probe_output(host, port, ssh_user, "ipmiutil health", timeout)
            if out:
                m = re.search(r"BMC version\s+([^\s,]+)", out, re.IGNORECASE)
                if m:
                    bmc_version = m.group(1).strip()
                    bmc_method  = "ipmiutil"
        else:
            # Linux in-band uses ipmitool. `ipmitool mc info` prints:
            #   Firmware Revision         : 1.40
            out = _ssh_probe_output(host, port, ssh_user, "sudo ipmitool mc info", timeout)
            if out:
                for line in out.splitlines():
                    if "firmware revision" in line.lower():
                        bmc_version = line.split(":", 1)[-1].strip()
                        bmc_method  = "ipmitool"
                        break

    if not bmc_version and bmc_host:
        bmc_version = _redfish_firmware_version(bmc_host, bmc_user, bmc_pass, timeout)
        if bmc_version:
            bmc_method = "redfish"

    return {
        "bios_version": bios_version or "N/A",
        "bmc_version":  bmc_version or "N/A",
        "bmc_method":   bmc_method,
    }


def restore_dut_env(
    host: str, port: int, ssh_user: str, dut_os: str = "linux", timeout: int = 30
) -> bool:
    """SSH into the DUT and run the test-environment restore helper.

    On Linux, runs config.DUT_RESTORE_HELPER (installed by setup_dut.sh), which
    reverses the logind drop-in and sleep-target masks. On Windows, runs
    setup_dut.ps1 -Restore (config.DUT_RESTORE_HELPER_WIN), which reverses the
    power-scheme changes from setup_dut.ps1 step 6. Neither touches framework
    infrastructure (SSH key/service, sudoers, scheduled tasks, auto-logon).
    Never raises. Returns True on success, False on any failure (caller logs a
    manual fallback hint in the warning message).
    """
    log = logging.getLogger("function")
    if dut_os == "windows":
        remote_cmd = f'powershell -ExecutionPolicy Bypass -File "{config.DUT_RESTORE_HELPER_WIN}" -Restore'
        fallback_hint = f"{config.DUT_RESTORE_HELPER_WIN} -Restore"
    else:
        remote_cmd = f"sudo {config.DUT_RESTORE_HELPER}"
        fallback_hint = "sudo ./setup_dut.sh --restore"
    cmd = [
        "ssh",
        *ssh_base_opts(timeout),
        "-p", str(port),
        f"{ssh_user}@{host}",
        remote_cmd,
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, errors="replace",
            timeout=timeout + 10
        )
        if result.returncode == 0:
            log.info("DUT test-environment restored (%s@%s).", ssh_user, host)
            return True
        log.warning(
            "DUT restore failed (exit %d) — run manually: %s\n%s",
            result.returncode, fallback_hint, result.stderr.strip(),
        )
        return False
    except Exception as exc:
        log.warning(
            "DUT restore failed: %s — run manually: %s", exc, fallback_hint
        )
        return False


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
    dut_os: str = "windows",
) -> Optional[threading.Thread]:
    """Display an in-progress notification on the DUT (FWK032).

    Runs in a background daemon thread.  Returns the Thread object so the
    caller can optionally join() it before starting the next action.

    power_cycle.py: ignore the return value — ON_TIME (90 s) provides
      enough buffer; no need to block the test.
    reboot.py: join(timeout=N) before the next reboot command, otherwise
      the shutdown races ahead of the notification delivery.

    dut_os selects the per-platform mechanism (FWK032):
      "windows" — polls 'query session' until an Active desktop session
        exists (up to max_wait seconds), then sends 'msg * <message>'.
        This handles the race where sshd starts before the interactive
        logon session is ready.
      "linux"   — polls SSH readiness with a no-op command (up to max_wait
        seconds), then broadcasts the message to all TTYs with
        'wall <message>'. 'wall' does not require an active GUI/login
        session, so no session-detection step is needed.

    Fails silently throughout — msg.exe/wall may be unavailable or no user
    may be logged in.  Returns None when dry_run or no ssh_user.
    """
    if dry_run or not ssh_user or not host:
        return None

    def _worker():
        log = logging.getLogger("function")

        def _ssh(cmd):
            try:
                r = subprocess.run(
                    [
                        "ssh",
                        *ssh_base_opts(ssh_timeout),
                        "-p", str(port),
                        f"{ssh_user}@{host}",
                        cmd,
                    ],
                    timeout=ssh_timeout + 2,
                    capture_output=True,
                    text=True,
                    errors="replace",
                )
                return r.returncode, r.stdout
            except Exception as exc:
                log.debug("notify_dut SSH error: %s", exc)
                return -1, ""

        deadline = time.monotonic() + max_wait
        attempt = 0

        def _sleep_until_next_attempt() -> bool:
            """Wait before the next poll. Returns False when the budget is spent.

            The loop condition is evaluated BEFORE the SSH probe, and that probe
            blocks for up to ssh_timeout+2 s. On the last attempt it can overrun
            the deadline, leaving a NEGATIVE remaining time -- time.sleep() then
            raises ValueError and kills this thread with a traceback (BUG0040).
            Clamping here keeps the notification best-effort and silent (FWK032).
            """
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(retry_interval, remaining))
            return True

        if dut_os == "linux":
            while time.monotonic() < deadline:
                rc, _ = _ssh("true")
                log.debug("notify_dut: ssh readiness rc=%d", rc)
                if rc == 0:
                    _ssh(f"wall {message!r}")
                    log.info("notify_dut: wall sent on attempt %d", attempt + 1)
                    return
                attempt += 1
                log.info("notify_dut: SSH not ready yet (attempt %d/%d), retry in %.0fs",
                         attempt, int(max_wait / retry_interval), retry_interval)
                if not _sleep_until_next_attempt():
                    break

            log.warning("notify_dut: SSH not ready within %ds — wall notification skipped", max_wait)
            return

        while time.monotonic() < deadline:
            rc, out = _ssh("query session")
            log.debug("notify_dut: query session rc=%d out=%r", rc, out)
            if rc == 0 and "Active" in out:
                _ssh(f"msg * {message}")
                log.info("notify_dut: msg sent on attempt %d", attempt + 1)
                return
            attempt += 1
            log.info("notify_dut: no Active session yet (attempt %d/%d), retry in %.0fs",
                     attempt, int(max_wait / retry_interval), retry_interval)
            if not _sleep_until_next_attempt():
                break

        log.warning("notify_dut: no Active session within %ds — notification skipped", max_wait)

    def _safe_worker():
        """FWK032: the in-test notification is best-effort and must never be
        able to affect the test. An unhandled exception in a thread does not
        abort the run, but it does dump a traceback into the operator's console
        mid-test (BUG0040), which reads like a test failure. Swallow anything
        that escapes and record it as a warning instead.
        """
        try:
            _worker()
        except Exception as exc:
            logging.getLogger("function").warning(
                "notify_dut: notification failed (%s: %s) — ignored, test unaffected",
                type(exc).__name__, exc,
            )

    t = threading.Thread(target=_safe_worker, daemon=True, name="notify-dut")
    t.start()
    return t


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

def write_json(path: str, data: dict, retries: int = 3) -> None:
    """Atomically write dict to path (write to .tmp then rename).

    Retries on a transient OSError/FileNotFoundError during the tmp-write or
    rename step (e.g. a cloud-sync client or antivirus briefly touching the
    .tmp file). A long-running endurance test must not abort and lose hours
    of recorded cycles to a momentary filesystem hiccup (BUG0035).
    """
    tmp = path + ".tmp"
    last_exc = None
    for attempt in range(1, retries + 1):
        try:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            os.replace(tmp, path)
            return
        except OSError as exc:
            last_exc = exc
            if attempt < retries:
                time.sleep(0.2 * attempt)
    raise last_exc


def read_json(path: str):
    """Return parsed JSON at path, or None if the file does not exist."""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return None


# ---------- DUT-first session layout (LOG025) ----------

def dut_slug(value: str) -> str:
    """Sanitize a --dut-id/--host value into a filesystem-safe directory name."""
    value = (value or "").strip()
    if not value:
        return "unknown-dut"
    return re.sub(r"[^A-Za-z0-9._-]", "_", value)


class SessionTargetMismatch(RuntimeError):
    """Raised when a resumable session directory was created for a different
    DUT identity (host/port/ssh_user/...) than the one requested now."""

    def __init__(self, session_id: str, expected: dict, got: dict):
        self.session_id = session_id
        self.expected = expected
        self.got = got
        super().__init__(
            f"session {session_id} target mismatch: recorded={expected}, current={got}"
        )


class SessionCycleMismatch(RuntimeError):
    """Raised when an EXPLICIT --cycles differs from the resumable session's.

    Resuming reuses the original session's cycle target (LOG023/FWK013), which
    silently discards a different, explicitly-requested count -- an operator who
    asks for 300 cycles and gets a resumed 100-cycle run has no idea until the
    report says 100/100 (BUG0041). Refuse instead, and let them choose.
    """

    def __init__(self, session_id, session_m, requested_m):
        self.session_id  = session_id
        self.session_m   = session_m
        self.requested_m = requested_m
        super().__init__(
            f"resumable session {session_id} has m={session_m}, "
            f"but --cycles {requested_m} was requested"
        )


def session_age_hours(session_dir, meta: dict):
    """Hours since a session was last written, or None if undeterminable.

    Prefers the LOG023 `updated_at` field; falls back to `started_at`, then to
    meta.json's mtime so a session written by an older build (no timestamps)
    still gets an age rather than being treated as ageless and always resumable.
    """
    for key in ("updated_at", "started_at"):
        raw = (meta or {}).get(key)
        if raw:
            try:
                stamp = datetime.strptime(raw, "%Y-%m-%dT%H:%M:%S")
            except (ValueError, TypeError):
                continue
            return max(0.0, (datetime.now() - stamp).total_seconds() / 3600.0)
    try:
        mtime = os.path.getmtime(str(Path(session_dir) / "meta.json"))
    except OSError:
        return None
    return max(0.0, (time.time() - mtime) / 3600.0)


def resolve_session(base_dir: str, test: str, dut_id: str, target: dict,
                     requested_m: int, new_session: bool,
                     cycles_explicit: bool = False,
                     max_age_hours=None, force_resume: bool = False):
    """Resolve this run's session directory under <base_dir>/<dut_id>/ (LOG025).

    Sessions live at <base_dir>/<dut_id>/<test>_<session_id>/, keyed by DUT
    identity so concurrent runs against different DUTs sharing one --out base
    never contend for the same session-state file or collide on filenames
    (BUG0035 follow-up). Each session directory holds its own meta.json
    (the LOG023 session-state record) plus that session's log/result/report.

    Auto-resume may optionally be bounded by age (LOG026): an incomplete session
    older than `max_age_hours` is treated as abandoned and skipped. This is OFF
    by default (config.RESUME_MAX_AGE_HOURS = -1) because an endurance run
    legitimately spans weekends and holidays. `force_resume` (--resume) ignores
    the bound; `new_session` (--new-session) beats both.

    Returns (session_dir: Path, session_id: str, m: int, start_n: int,
             meta: dict, resuming: bool, skipped: list). `skipped` describes
    incomplete sessions passed over for age, so the caller can say so out loud
    instead of leaving the operator to wonder. Raises SessionTargetMismatch if
    a resumable session directory exists but was recorded for a different
    target identity.
    """
    dut_dir = Path(base_dir) / dut_id
    dut_dir.mkdir(parents=True, exist_ok=True)

    if max_age_hours is None:
        max_age_hours = getattr(config, "RESUME_MAX_AGE_HOURS", -1)

    candidate = None
    skipped   = []
    if not new_session:
        for child in sorted(dut_dir.glob(f"{test}_*"), reverse=True):
            meta = read_json(str(child / "meta.json"))
            if not (meta and meta.get("status") == "running"
                    and meta.get("n", 0) < meta.get("m", 0)):
                continue
            age = session_age_hours(child, meta)
            stale = (not force_resume and max_age_hours >= 0
                     and (max_age_hours == 0
                          or (age is not None and age > max_age_hours)))
            if stale:
                skipped.append({
                    "session_id": meta.get("session_id", child.name),
                    "age_hours":  age,
                    "n":          meta.get("n", 0),
                    "m":          meta.get("m", 0),
                    "path":       str(child),
                })
                continue
            candidate = (child, meta)
            break

    if candidate is not None:
        session_dir, meta = candidate
        if meta.get("target") != target:
            raise SessionTargetMismatch(meta.get("session_id"), meta.get("target"), target)
        # An explicitly-requested cycle count that differs from the session's is
        # a different intent, not a resume -- refuse rather than silently run the
        # old target (BUG0041).
        if cycles_explicit and meta.get("m") != requested_m:
            raise SessionCycleMismatch(meta.get("session_id"), meta.get("m"), requested_m)
        session_id = meta["session_id"]
        m          = meta["m"]
        start_n    = meta["n"] + 1
        resuming   = True
    else:
        session_id = now_ts()
        m          = requested_m
        start_n    = 1
        session_dir = dut_dir / f"{test}_{session_id}"
        session_dir.mkdir(parents=True, exist_ok=True)
        meta = {
            "session_id": session_id,
            "test":       test,
            "dut_id":     dut_id,
            "m":          m,
            "n":          0,
            "status":     "running",
            "started_at": now_iso(),
            "updated_at": now_iso(),
            "target":     target,
        }
        write_json(str(session_dir / "meta.json"), meta)
        resuming = False

    return session_dir, session_id, m, start_n, meta, resuming, skipped


def log_session_banner(log, resuming: bool, session_id: str, session_dir,
                       start_n: int, m: int, skipped=None,
                       forced_resume: bool = False, new_session: bool = False) -> None:
    """Announce NEW vs RESUMING before the run starts (LOG026).

    Whether this run continues an earlier one is the single most consequential
    fact about it -- it decides how many cycles actually execute and which
    result.json grows -- so it is stated as a banner, not as one field among
    twenty. Operators should never have to delete the output directory just to
    be sure they are getting a clean run.
    """
    bar = "=" * 64
    log.info(bar)
    if resuming:
        log.info("  RESUMING an existing session — cycles %d-%d of %d", start_n, m, m)
        log.info("  Session   : %s", session_id)
        log.info("  Directory : %s", session_dir)
        log.info("  Already done: %d cycle(s); this run appends to the SAME "
                 "result.json and report.", start_n - 1)
        if forced_resume:
            log.info("  (--resume given: the session age limit was bypassed.)")
        log.info("  To start a clean run instead, re-run with --new-session.")
    else:
        log.info("  NEW session — cycles 1-%d", m)
        log.info("  Session   : %s", session_id)
        log.info("  Directory : %s", session_dir)
        if new_session:
            log.info("  (--new-session given: any incomplete session was left untouched.)")
    for s in (skipped or []):
        log.warning("  Skipped incomplete session %s (%d/%d cycles, last updated "
                    "%.1f h ago — older than the resume limit); it was NOT resumed.",
                    s["session_id"], s["n"], s["m"], s["age_hours"])
        log.warning("    To continue it instead, re-run with --resume.")
    log.info(bar)


# Backwards-compatible alias (result.json is written via the same atomic path)
def write_result_json(path: str, data: dict) -> None:
    """Atomically write result dict to path (see write_json)."""
    write_json(path, data)


# ---------- System configuration inventory (FWK037) ----------
# Best-effort snapshot of the DUT's hardware/firmware/OS configuration, gathered
# over SSH, so every test's result.json and HTML report is self-describing:
# "these results were produced on THIS CPU with THIS much RAM". Informational
# only -- it never changes a verdict, and anything unavailable becomes None/N/A.
#
# Memory is reported as BOTH installed (DMI/SPD) and usable (OS) with a DET002
# usability verdict, because a DIMM can be populated yet not trained/enabled:
# Linux shows 6 populated DIMMs via dmidecode while /proc/meminfo sees only part
# of it; Windows shows the same natively as "192 GB installed (128 GB usable)".

_MEM_TOLERANCE_FLOOR = 2 * 1024 ** 3     # 2 GiB
_MEM_TOLERANCE_FRAC  = 0.03              # 3% of installed


def _mem_usability_verdict(installed, usable, dimm_count, smallest_dimm):
    """DET002: classify installed-vs-usable memory. Returns (result, reason)."""
    if not installed or not usable:
        return "UNKNOWN", ("memory inventory unavailable on the DUT - cannot "
                           "verify DIMM usability (not a pass)")
    gap = max(0, installed - usable)
    threshold = max(int(installed * _MEM_TOLERANCE_FRAC), _MEM_TOLERANCE_FLOOR)
    if smallest_dimm:
        threshold = max(threshold, smallest_dimm // 2)
    gib = lambda b: f"{b / 1024 ** 3:.1f}"
    if gap > threshold:
        return "Fail", (
            f"installed {gib(installed)} GiB across {dimm_count or '?'} DIMM(s) but only "
            f"{gib(usable)} GiB usable - {gib(gap)} GiB missing (> {gib(threshold)} GiB "
            f"tolerance): one or more populated DIMMs were not trained/enabled "
            f"(defective DIMM, slot, or seating)"
        )
    return "Pass", (
        f"installed {gib(installed)} GiB across {dimm_count or '?'} DIMM(s), "
        f"{gib(usable)} GiB usable - {gib(gap)} GiB reserved, within "
        f"{gib(threshold)} GiB tolerance"
    )


def _parse_linux_sysinfo(raw: str) -> dict:
    """Parse the KEY=VALUE block emitted by the Linux inventory one-liner."""
    info = {}
    for line in (raw or "").splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            info[k.strip()] = v.strip()
    return info


def collect_system_info(host: str, port: int, ssh_user: str, dut_os: str = "linux",
                        timeout: int = 20, dry_run: bool = False) -> dict:
    """Collect the DUT's system configuration inventory over SSH (FWK037).

    Returns a dict with hostname/os/product/baseboard/bios/cpu/memory keys;
    every field is best-effort and may be None. Never raises.
    """
    empty = {
        "hostname": None, "os": None, "kernel": None, "product": None,
        "baseboard": None, "serial": None, "bios_version": None,
        "cpu_model": None, "cpu_sockets": None, "cpu_cores_per_socket": None,
        "cpu_logical": None,
        "memory": {"installed_bytes": None, "usable_bytes": None,
                   "dimm_populated_count": None, "gap_bytes": None,
                   "result": "UNKNOWN", "reason": "not collected"},
    }
    if dry_run:
        out = dict(empty)
        out["hostname"] = "DRY-RUN"
        return out
    if not (host and ssh_user):
        return empty

    try:
        if dut_os == "windows":
            return _collect_system_info_windows(host, port, ssh_user, timeout, empty)
        return _collect_system_info_linux(host, port, ssh_user, timeout, empty)
    except Exception as exc:                      # never break a test over this
        log.warning("collect_system_info failed: %s", exc)
        return empty


def _collect_system_info_linux(host, port, ssh_user, timeout, empty) -> dict:
    # One SSH round-trip: emit KEY=VALUE lines. dmidecode needs root (NOPASSWD
    # sudo is configured by setup_dut.sh); if it is unavailable those keys are
    # simply absent and degrade to None/UNKNOWN.
    cmd = (
        "echo HOST=$(hostname 2>/dev/null); "
        "echo KERNEL=$(uname -r 2>/dev/null); "
        ". /etc/os-release 2>/dev/null && echo OS=\"$PRETTY_NAME\"; "
        "echo PRODUCT=$(sudo -n dmidecode -s system-product-name 2>/dev/null | head -n1); "
        "echo BOARD=$(sudo -n dmidecode -s baseboard-product-name 2>/dev/null | head -n1); "
        "echo SERIAL=$(sudo -n dmidecode -s system-serial-number 2>/dev/null | head -n1); "
        "echo BIOS=$(sudo -n dmidecode -s bios-version 2>/dev/null | head -n1); "
        "echo CPU=$(LANG=C lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}'); "
        "echo SOCKETS=$(LANG=C lscpu 2>/dev/null | awk -F': +' '/^Socket\\(s\\)/{print $2; exit}'); "
        "echo CORES=$(LANG=C lscpu 2>/dev/null | awk -F': +' '/^Core\\(s\\) per socket/{print $2; exit}'); "
        "echo LOGICAL=$(LANG=C lscpu 2>/dev/null | awk -F': +' '/^CPU\\(s\\)/{print $2; exit}'); "
        "echo USABLE=$(awk '/^MemTotal:/{printf \"%.0f\", $2*1024; exit}' /proc/meminfo 2>/dev/null); "
        "echo DIMMS=$(sudo -n dmidecode -t memory 2>/dev/null | awk '/^[ \\t]*Size:/{"
        "l=$0; sub(/^[ \\t]*Size:[ \\t]*/,\"\",l); "
        "if (l ~ /No Module Installed|Not Installed|Unknown/) next; if (l+0>0) c++} END{printf \"%d\", c+0}'); "
        "echo INSTALLED=$(sudo -n dmidecode -t memory 2>/dev/null | awk '/^[ \\t]*Size:/{"
        "l=$0; sub(/^[ \\t]*Size:[ \\t]*/,\"\",l); "
        "if (l ~ /No Module Installed|Not Installed|Unknown/) next; n=l+0; if(n<=0) next; "
        "if (l ~ /[Tt]B/) b=n*1024*1024*1024*1024; else if (l ~ /[Gg]B/) b=n*1024*1024*1024; "
        "else if (l ~ /[Mm]B/) b=n*1024*1024; else if (l ~ /[Kk]B/) b=n*1024; else b=n; t+=b} "
        "END{if (t>0) printf \"%.0f\", t}'); "
        "echo SMALLEST=$(sudo -n dmidecode -t memory 2>/dev/null | awk '/^[ \\t]*Size:/{"
        "l=$0; sub(/^[ \\t]*Size:[ \\t]*/,\"\",l); "
        "if (l ~ /No Module Installed|Not Installed|Unknown/) next; n=l+0; if(n<=0) next; "
        "if (l ~ /[Tt]B/) b=n*1024*1024*1024*1024; else if (l ~ /[Gg]B/) b=n*1024*1024*1024; "
        "else if (l ~ /[Mm]B/) b=n*1024*1024; else if (l ~ /[Kk]B/) b=n*1024; else b=n; "
        "if (m==0 || b<m) m=b} END{if (m>0) printf \"%.0f\", m}')"
    )
    raw = _ssh_probe_output(host, port, ssh_user, cmd, timeout)
    if not raw:
        return empty
    d = _parse_linux_sysinfo(raw)
    to_int = lambda k: int(d[k]) if d.get(k, "").isdigit() else None

    installed = to_int("INSTALLED")
    usable    = to_int("USABLE")
    dimms     = to_int("DIMMS")
    smallest  = to_int("SMALLEST")
    result, reason = _mem_usability_verdict(installed, usable, dimms, smallest)

    return {
        "hostname":  d.get("HOST") or None,
        "os":        d.get("OS") or None,
        "kernel":    d.get("KERNEL") or None,
        "product":   d.get("PRODUCT") or None,
        "baseboard": d.get("BOARD") or None,
        "serial":    d.get("SERIAL") or None,
        "bios_version": d.get("BIOS") or None,
        "cpu_model": d.get("CPU") or None,
        "cpu_sockets": to_int("SOCKETS"),
        "cpu_cores_per_socket": to_int("CORES"),
        "cpu_logical": to_int("LOGICAL"),
        "memory": {
            "installed_bytes": installed,
            "usable_bytes": usable,
            "dimm_populated_count": dimms,
            "gap_bytes": (max(0, installed - usable) if installed and usable else None),
            "result": result,
            "reason": reason,
        },
    }


def _collect_system_info_windows(host, port, ssh_user, timeout, empty) -> dict:
    # PowerShell one-liner emitting the same KEY=VALUE contract. installed =
    # sum(Win32_PhysicalMemory.Capacity); usable = TotalPhysicalMemory -- the
    # pair Windows itself displays as "X installed (Y usable)".
    ps = (
        "$os=Get-CimInstance Win32_OperatingSystem;"
        "$cs=Get-CimInstance Win32_ComputerSystem;"
        "$b=Get-CimInstance Win32_BIOS;"
        "$bb=Get-CimInstance Win32_BaseBoard;"
        "$p=Get-CimInstance Win32_ComputerSystemProduct;"
        "$c=@(Get-CimInstance Win32_Processor);"
        "$d=@(Get-CimInstance Win32_PhysicalMemory|Where-Object{$_.Capacity -gt 0});"
        "Write-Output ('HOST='+$env:COMPUTERNAME);"
        "Write-Output ('OS='+$os.Caption);"
        "Write-Output ('KERNEL='+$os.Version);"
        "Write-Output ('PRODUCT='+$p.Name);"
        "Write-Output ('BOARD='+$bb.Product);"
        "Write-Output ('SERIAL='+$b.SerialNumber);"
        "Write-Output ('BIOS='+$b.SMBIOSBIOSVersion);"
        "Write-Output ('CPU='+$c[0].Name);"
        "Write-Output ('SOCKETS='+$c.Count);"
        "Write-Output ('CORES='+(($c|Measure-Object NumberOfCores -Sum).Sum));"
        "Write-Output ('LOGICAL='+(($c|Measure-Object NumberOfLogicalProcessors -Sum).Sum));"
        "Write-Output ('USABLE='+$cs.TotalPhysicalMemory);"
        "Write-Output ('DIMMS='+$d.Count);"
        "Write-Output ('INSTALLED='+(($d|Measure-Object Capacity -Sum).Sum));"
        "Write-Output ('SMALLEST='+(($d|Measure-Object Capacity -Minimum).Minimum))"
    )
    raw = _ssh_probe_output(host, port, ssh_user, f'powershell -NoProfile -Command "{ps}"', timeout)
    if not raw:
        return empty
    d = _parse_linux_sysinfo(raw)          # same KEY=VALUE contract
    to_int = lambda k: int(d[k]) if d.get(k, "").isdigit() else None

    installed = to_int("INSTALLED")
    usable    = to_int("USABLE")
    dimms     = to_int("DIMMS")
    smallest  = to_int("SMALLEST")
    result, reason = _mem_usability_verdict(installed, usable, dimms, smallest)

    return {
        "hostname":  d.get("HOST") or None,
        "os":        d.get("OS") or None,
        "kernel":    d.get("KERNEL") or None,
        "product":   d.get("PRODUCT") or None,
        "baseboard": d.get("BOARD") or None,
        "serial":    d.get("SERIAL") or None,
        "bios_version": d.get("BIOS") or None,
        "cpu_model": d.get("CPU") or None,
        "cpu_sockets": to_int("SOCKETS"),
        "cpu_cores_per_socket": None,
        "cpu_logical": to_int("LOGICAL"),
        "memory": {
            "installed_bytes": installed,
            "usable_bytes": usable,
            "dimm_populated_count": dimms,
            "gap_bytes": (max(0, installed - usable) if installed and usable else None),
            "result": result,
            "reason": reason,
        },
    }


def log_system_info(info: dict) -> None:
    """Log the FWK037 inventory as a readable block."""
    if not info:
        return
    gib = lambda b: f"{b / 1024 ** 3:.1f} GiB" if b else "N/A"
    m = info.get("memory") or {}
    log.info("System configuration (FWK037):")
    log.info("  Host / OS  : %s / %s", info.get("hostname") or "N/A", info.get("os") or "N/A")
    log.info("  Product    : %s (board: %s)", info.get("product") or "N/A",
             info.get("baseboard") or "N/A")
    log.info("  BIOS       : %s", info.get("bios_version") or "N/A")
    log.info("  CPU        : %s (sockets=%s logical=%s)", info.get("cpu_model") or "N/A",
             info.get("cpu_sockets") or "N/A", info.get("cpu_logical") or "N/A")
    log.info("  Memory     : installed %s across %s DIMM(s), usable %s  [%s]",
             gib(m.get("installed_bytes")), m.get("dimm_populated_count") or "N/A",
             gib(m.get("usable_bytes")), m.get("result") or "N/A")
    if m.get("result") == "Fail":
        log.warning("  Memory     : %s", m.get("reason"))
