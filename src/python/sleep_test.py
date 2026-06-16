#!/usr/bin/env python3
# sleep_test.py - Pi-controlled sleep / suspend-resume endurance test (SLP001-SLP005)
#
# This is the CONTROL-NODE (Pi) half of the sleep test.  It mirrors reboot.py:
# a sleeping DUT has no network, so the Pi cannot wake it remotely.  Instead the
# Pi SSH-invokes the DUT-local helper (sleep_test.ps1 -OneShot), which arms a
# SOFTWARE RTC wake timer and then suspends the DUT; the Pi then judges the cycle
# PURELY by network liveness:
#
#   went offline  = the DUT entered sleep
#   came back     = the RTC wake timer fired and the DUT resumed
#
# The Pi-controlled tool is what catches a DUT that NEVER wakes (NO_WAKE): the
# external observer sees the DUT stay offline past the wake timeout.  (The
# DUT-local sleep_test.ps1 cannot self-record that, because the script is itself
# suspended.)
#
# Usage:
#   python sleep_test.py --host 10.0.0.137 --ssh-user nimitz4
#
# Options (defaults come from config.py; --help lists them):
#   --host IP            DUT IP/hostname (required for liveness)
#   --port N             TCP port for liveness check (default 22)
#   --cycles N           sleep-wake cycles PER state (default config.SLEEP_CYCLES)
#   --states S           "auto" | "S3" | "S4" | "S3,S4" (default config.SLEEP_STATES)
#   --pre-delay SEC      seconds in Windows before each sleep (default config.SLEEP_PRE_DELAY_SEC)
#   --wake-after SEC     RTC wake timer seconds asleep (default config.SLEEP_WAKE_AFTER_SEC)
#   --dead-timeout SEC   max wait for DUT to go offline (default config.SLEEP_DEAD_TIMEOUT_SEC)
#   --wake-timeout SEC   max wait for DUT to come back online (default config.SLEEP_WAKE_TIMEOUT_SEC)
#   --ssh-user USER      SSH login (required to drive the DUT helper)
#   --remote-helper PATH DUT path of sleep_test.ps1 (default config.SLEEP_REMOTE_HELPER)
#   --out DIR            output directory (default config.LOG_DIR)
#   --no-check           skip liveness checks (logic test only)
#   --dry-run            do not SSH or suspend; simulate PASS
#   --new-session        force a new session per state (LOG023)
#   --pin / --type / --init-wait   DUT init (FWK031), as in reboot.py
#
# Verdicts per cycle:
#   PASS      - DUT slept (went offline) and woke (came back) within the timeouts
#   NO_SLEEP  - DUT never went offline after the sleep command (suspend failed)
#   NO_WAKE   - DUT slept but never came back within the wake timeout (stuck asleep)
#   SSH_ERROR - the sleep command could not be sent (DUT unreachable before sleep)

import argparse
import logging
import signal
import subprocess
import time
from pathlib import Path

import config
import function
from liveness import LivenessChecker
from relay import RelayController
from report import generate_report

log = logging.getLogger("sleep_test")

# ── verdicts ──────────────────────────────────────────────────────────────────
PASS      = "PASS"
NO_SLEEP  = "NO_SLEEP"
NO_WAKE   = "NO_WAKE"
SSH_ERROR = "SSH_ERROR"

# ── global state (for signal handler) ─────────────────────────────────────────
_stop_requested = False


def _sigint_handler(sig, frame):
    global _stop_requested
    print("\n[!] Ctrl-C received - finishing current cycle then stopping ...")
    _stop_requested = True


# ── argument parsing ───────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Sleep/suspend endurance test (Pi-controlled, SSH)")
    p.add_argument("--host",        default=config.DUT_HOST,
                   help="DUT IP or hostname (required for liveness checks)")
    p.add_argument("--port",        default=config.DUT_PORT, type=int,
                   help="TCP port to probe (default: %(default)s)")
    p.add_argument("--cycles",      default=config.SLEEP_CYCLES, type=int,
                   help="Sleep-wake cycles per state (default: %(default)s)")
    p.add_argument("--states",      default=config.SLEEP_STATES,
                   help="Sleep states to test: auto|S3|S4|S3,S4 (default: %(default)s)")
    p.add_argument("--pre-delay",   default=config.SLEEP_PRE_DELAY_SEC, type=int,
                   dest="pre_delay",
                   help="Seconds in Windows before each sleep (default: %(default)s)")
    p.add_argument("--wake-after",  default=config.SLEEP_WAKE_AFTER_SEC, type=int,
                   dest="wake_after",
                   help="RTC wake timer seconds asleep (default: %(default)s)")
    p.add_argument("--dead-timeout", default=config.SLEEP_DEAD_TIMEOUT_SEC, type=int,
                   dest="dead_timeout",
                   help="Max seconds waiting for DUT to go offline (default: %(default)s)")
    p.add_argument("--wake-timeout", default=config.SLEEP_WAKE_TIMEOUT_SEC, type=int,
                   dest="wake_timeout",
                   help="Max seconds waiting for DUT to come back online (default: %(default)s)")
    p.add_argument("--ssh-user",    default=config.SHUTDOWN_SSH_USER, dest="ssh_user",
                   help="SSH username to drive the DUT helper (required at runtime)")
    p.add_argument("--remote-helper", default=config.SLEEP_REMOTE_HELPER, dest="remote_helper",
                   help="DUT path of sleep_test.ps1 (default: %(default)s)")
    p.add_argument("--out",         default=config.LOG_DIR,
                   help="Output directory for logs (default: %(default)s)")
    p.add_argument("--no-check",    action="store_true",
                   help="Disable network liveness checks")
    p.add_argument("--dry-run",     action="store_true",
                   help="Simulate without SSH or suspend")
    p.add_argument("--new-session", action="store_true", dest="new_session",
                   help="Force a new session even if an incomplete one exists (LOG023)")
    p.add_argument("--early-fail-threshold", default=config.EARLY_FAIL_THRESHOLD, type=int,
                   dest="early_fail_threshold",
                   help="Abort if first N cycles all fail before any PASS; 0 = never "
                        "(default: %(default)s)")
    p.add_argument("--max-consecutive-fails", default=config.MAX_CONSECUTIVE_FAILS, type=int,
                   dest="max_consecutive_fails",
                   help="Abort after N consecutive mid-run failures; 0 = never (default: %(default)s)")
    # ── Init phase (FWK031): normalise DUT state before the first cycle ───────
    p.add_argument("--pin",         default=config.GPIO_PIN, type=int,
                   help="GPIO BOARD pin for init-phase power recovery (default: %(default)s)")
    p.add_argument("--type",        default=config.POWER_TYPE, choices=["ATX", "AT"],
                   help="PSU type for init-phase power recovery (default: %(default)s)")
    p.add_argument("--init-wait",   default=config.INIT_WAIT_SEC, type=int, dest="init_wait",
                   help="GPIO-unavailable fallback: wait for a booting DUT; 0 = fail now "
                        "(default: %(default)s)")
    return p.parse_args()


# ── SSH helpers ─────────────────────────────────────────────────────────────────

def _ssh_run(args: argparse.Namespace, remote_cmd: str, timeout: int):
    """Run a command on the DUT over SSH. Returns subprocess.CompletedProcess or None."""
    cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout=10",
        "-p", str(args.port),
        f"{args.ssh_user}@{args.host}",
        remote_cmd,
    ]
    try:
        return subprocess.run(cmd, timeout=timeout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.TimeoutExpired:
        log.warning("SSH command timed out after %ds: %s", timeout, remote_cmd)
        return None
    except Exception as exc:
        log.warning("SSH command error: %s", exc)
        return None


def _ssh_sleep(args: argparse.Namespace, state: str) -> bool:
    """Tell the DUT to arm its wake timer and enter `state`. Returns True if sent.

    SSH drops as the DUT suspends, so a non-zero/255 exit or a timeout is still a
    'command sent' - the liveness checks decide whether it actually slept/woke.
    """
    if args.dry_run:
        log.info("DRY-RUN: would SSH %s@%s -> sleep_test.ps1 -OneShot -State %s -WakeAfter %d",
                 args.ssh_user, args.host, state, args.wake_after)
        return True

    remote_cmd = (
        f'powershell -ExecutionPolicy Bypass -NoProfile -File "{args.remote_helper}" '
        f'-OneShot -State {state} -WakeAfter {args.wake_after}'
    )
    log.info("SSH sleep: %s@%s  state=%s  wake-after=%ds", args.ssh_user, args.host, state, args.wake_after)
    # Allow time for the helper to arm the timer + begin suspend before SSH drops.
    res = _ssh_run(args, remote_cmd, timeout=args.wake_after + args.dead_timeout + 30)
    if res is None:
        # Timeout: the DUT likely suspended and SSH never returned cleanly. Treat
        # as sent; the offline check confirms whether it really slept.
        return True
    if res.returncode in (0, 255):
        return True
    stderr_text = (res.stderr or b"").decode(errors="replace").strip()
    log.warning("SSH sleep command returned %d%s", res.returncode,
                f": {stderr_text}" if stderr_text else "")
    return False


def detect_sleep_states(args: argparse.Namespace) -> list:
    """SSH 'powercfg /a' to the DUT and parse the supported states among S1-S4/S0."""
    if args.dry_run or args.no_check or not args.ssh_user or not args.host:
        return ["S3"]   # cannot probe - assume S3 for dry/no-check runs
    res = _ssh_run(args, "powercfg /a", timeout=20)
    if res is None or res.returncode != 0:
        log.warning("powercfg /a failed over SSH - assuming S3 only")
        return ["S3"]
    text = (res.stdout or b"").decode(errors="replace")
    states, in_avail = [], False
    for ln in text.splitlines():
        if "are available on this system" in ln:
            in_avail = True
            continue
        if "are not available" in ln:
            in_avail = False
            continue
        if not in_avail:
            continue
        if "(S3)" in ln and "S3" not in states:
            states.append("S3")
        elif "Hibernate" in ln and "S4" not in states:
            states.append("S4")
        elif "(S1)" in ln and "S1" not in states:
            states.append("S1")
        elif "(S2)" in ln and "S2" not in states:
            states.append("S2")
        elif "S0 Low Power Idle" in ln and "S0" not in states:
            states.append("S0")
    log.info("DUT supported sleep states: %s", ", ".join(states) if states else "(none)")
    return states


def resolve_states(requested: str, supported: list) -> list:
    """Map the --states selection against what the DUT supports."""
    if requested.strip().lower() == "auto":
        sel = [s for s in supported if s in ("S3", "S4")]
        if not sel:
            sel = [s for s in supported if s in ("S0", "S1", "S2")]
        return sel
    sel = []
    for w in (x.strip().upper() for x in requested.replace(" ", ",").split(",")):
        if not w:
            continue
        if w in supported:
            sel.append(w)
        else:
            log.warning("Requested state %s not supported on this DUT - skipping", w)
    return sel


# ── one cycle ──────────────────────────────────────────────────────────────────

def run_one_cycle(n: int, total: int, state: str, args: argparse.Namespace, checker) -> dict:
    """Execute one sleep-wake cycle for `state` and return a cycle-record dict."""
    rec = {
        "n":             n,
        "t_start":       function.now_iso(),
        "t_sleep_cmd":   None,
        "t_offline":     None,
        "t_online":      None,
        "boot_time_sec": None,
        "sleep_state":   state,
        "verdict":       SSH_ERROR,
        "notes":         "",
    }

    log.info("--- Cycle %d / %d  state=%s ---", n, total, state)

    # Phase 1: let the DUT sit in Windows (settle / soak).
    if not args.dry_run:
        time.sleep(args.pre_delay)

    # Pre-check: confirm the DUT is reachable before issuing the sleep command.
    if checker and not args.dry_run and not checker.ping():
        rec["notes"] = "DUT not reachable before sleep command (ping failed)"
        log.warning("Cycle %d: SSH_ERROR - DUT not pingable before sleep", n)
        return rec

    # Phase 2: arm wake timer + suspend (over SSH).
    rec["t_sleep_cmd"] = function.now_iso()
    t0 = time.monotonic()
    if not _ssh_sleep(args, state):
        rec["notes"] = "SSH sleep command failed"
        log.warning("Cycle %d: SSH_ERROR", n)
        return rec

    # Phase 3: wait for the DUT to go offline (entered sleep).
    if checker and not args.dry_run:
        dead, _ = checker.wait_until_dead(args.dead_timeout)
        rec["t_offline"] = function.now_iso()
        if not dead:
            rec["verdict"] = NO_SLEEP
            rec["notes"]   = f"DUT did not go offline within {args.dead_timeout}s (suspend failed)"
            log.warning("Cycle %d: NO_SLEEP", n)
            return rec
    else:
        rec["t_offline"] = function.now_iso()

    # Phase 4: wait for the DUT to come back online (RTC wake fired).
    if checker and not args.dry_run:
        alive, _ = checker.wait_until_alive(args.wake_timeout)
        rec["t_online"] = function.now_iso()
        if not alive:
            rec["verdict"] = NO_WAKE
            rec["notes"]   = f"DUT did not wake within {args.wake_timeout}s (stuck asleep)"
            log.warning("Cycle %d: NO_WAKE", n)
            return rec
        # Round-trip wake time: sleep command -> back online (SLP003).
        rec["boot_time_sec"] = round(time.monotonic() - t0, 2)
        log.info("Cycle %d: PASS - round-trip %.1f s", n, rec["boot_time_sec"])
    else:
        rec["t_online"]      = function.now_iso()
        rec["boot_time_sec"] = round(time.monotonic() - t0, 2)

    rec["verdict"] = PASS
    return rec


# ── summary / result helpers ────────────────────────────────────────────────────

def _build_summary(cycles: list, target: int) -> dict:
    verdicts = [c["verdict"] for c in cycles]
    fail_breakdown = {
        NO_SLEEP:  verdicts.count(NO_SLEEP),
        NO_WAKE:   verdicts.count(NO_WAKE),
        SSH_ERROR: verdicts.count(SSH_ERROR),
    }
    return {
        "cycles_target":  target,
        "total_ran":      len(cycles),
        "pass":           verdicts.count(PASS),
        "fail":           sum(fail_breakdown.values()),
        "fail_breakdown": fail_breakdown,
    }


def _new_result(args: argparse.Namespace, state: str, session_id: str, m: int) -> dict:
    return {
        "schema_version": "1.1",
        "test_name":      f"sleep_{state}",
        "session_id":     session_id,
        "started_at":     function.now_iso(),
        "ended_at":       None,
        "config": {
            "dut_host":         args.host,
            "dut_port":         args.port,
            "sleep_state":      state,
            "cycles_target":    m,
            "pre_delay_sec":    args.pre_delay,
            "wake_after_sec":   args.wake_after,
            "dead_timeout_sec": args.dead_timeout,
            "wake_timeout_sec": args.wake_timeout,
            "ssh_user":         args.ssh_user or None,
        },
        "cycles":          [],
        "summary":         {},
        "overall_verdict": "RUNNING",
    }


def run_state(state: str, args: argparse.Namespace, checker, out_dir: Path) -> str:
    """Run a full endurance session for one sleep state. Returns the overall verdict."""
    session_path = out_dir / f"sleep_{state}_session.json"
    session = function.read_json(str(session_path))
    resuming = bool(
        session
        and session.get("status") == "running"
        and session.get("n", 0) < session.get("m", 0)
        and not args.new_session
    )

    if resuming:
        session_id = session["session_id"]
        m          = session["m"]
        start_n    = session["n"] + 1
    else:
        session_id = function.now_ts()
        m          = args.cycles
        start_n    = 1
        session = {
            "session_id": session_id, "test": f"sleep_{state}", "state": state,
            "m": m, "n": 0, "status": "running",
            "started_at": function.now_iso(), "updated_at": function.now_iso(),
        }
        function.write_json(str(session_path), session)

    stem      = f"sleep_{state}_{session_id}"
    json_path = out_dir / f"{stem}.result.json"

    log.info("=== State %s : m=%d, starting at n=%d%s ===",
             state, m, start_n, "  (RESUMING)" if resuming else "")

    if resuming:
        result = function.read_json(str(json_path)) or _new_result(args, state, session_id, m)
        result["cycles"] = result.get("cycles", [])[: session["n"]]
    else:
        result = _new_result(args, state, session_id, m)

    consecutive_fails = 0
    has_had_success   = any(c.get("verdict") == PASS for c in result.get("cycles", []))
    last_n = start_n - 1

    for n in range(start_n, m + 1):
        if _stop_requested:
            log.info("Stop requested - exiting %s loop after cycle %d", state, n - 1)
            break

        rec = run_one_cycle(n, m, state, args, checker)
        result["cycles"].append(rec)
        last_n = n

        if rec["verdict"] == PASS:
            has_had_success   = True
            consecutive_fails = 0
        else:
            consecutive_fails += 1
            if not has_had_success:
                if (args.early_fail_threshold > 0
                        and consecutive_fails >= args.early_fail_threshold):
                    log.error("First %d cycles all failed before any PASS - aborting %s. "
                              "Check host, SSH credentials, remote helper path, and DUT state.",
                              args.early_fail_threshold, state)
                    break
            else:
                if (args.max_consecutive_fails > 0
                        and consecutive_fails >= args.max_consecutive_fails):
                    log.error("Reached %d consecutive mid-run failures - aborting %s.",
                              args.max_consecutive_fails, state)
                    break

        result["summary"] = _build_summary(result["cycles"], m)
        result["overall_verdict"] = "RUNNING"
        function.write_result_json(str(json_path), result)

        session["n"] = n
        session["updated_at"] = function.now_iso()
        function.write_json(str(session_path), session)

    if last_n >= m and not _stop_requested:
        session["status"] = "complete"
    session["n"] = last_n
    session["updated_at"] = function.now_iso()
    function.write_json(str(session_path), session)

    result["ended_at"] = function.now_iso()
    summary = _build_summary(result["cycles"], m)
    result["summary"] = summary
    if summary["fail"] == 0 and summary["total_ran"] > 0:
        result["overall_verdict"] = PASS
    elif summary["total_ran"] == 0:
        result["overall_verdict"] = "NO_DATA"
    else:
        result["overall_verdict"] = "FAIL"
    function.write_result_json(str(json_path), result)

    html_path = out_dir / f"{stem}.report.html"
    generate_report(result, str(html_path))

    s = result["summary"]
    log.info("State %s: %s  (%d/%d PASS)  report=%s",
             state, result["overall_verdict"], s["pass"], s["total_ran"], html_path)
    return result["overall_verdict"]


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> int:
    args = parse_args()

    if not args.ssh_user and not args.dry_run and not args.no_check:
        print("ERROR: --ssh-user is required for sleep_test.py (it drives the DUT helper).")
        print("       Use --dry-run to test the logic without a real DUT.")
        return 1

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    function.setup_logging(str(out_dir / "sleep_test.log"))
    signal.signal(signal.SIGINT, _sigint_handler)

    log.info("Sleep Test (Pi-controlled)")
    log.info("  Host       : %s", args.host or "(liveness disabled)")
    log.info("  Cycles     : %d per state", args.cycles)
    log.info("  Pre-delay  : %ds   Wake-after: %ds", args.pre_delay, args.wake_after)
    log.info("  Dead TO    : %ds   Wake TO   : %ds", args.dead_timeout, args.wake_timeout)
    log.info("  SSH user   : %s", args.ssh_user or "(none)")
    log.info("  Remote     : %s", args.remote_helper)
    if args.dry_run:
        log.info("  *** DRY-RUN - SSH/suspend will NOT be performed ***")

    # Liveness checker
    checker = None
    if not args.no_check and args.host:
        checker = LivenessChecker(
            host=args.host, port=args.port,
            ping_count=config.PING_COUNT,
            ping_timeout=config.PING_TIMEOUT_SEC,
            tcp_timeout=config.TCP_TIMEOUT_SEC,
        )
    elif not args.host:
        log.warning("DUT_HOST is not set - liveness checks disabled")

    # Detect & resolve sleep states.
    supported = detect_sleep_states(args)
    selected  = resolve_states(args.states, supported)
    if not selected:
        log.error("No usable sleep state to test (requested '%s', supported '%s').",
                  args.states, ",".join(supported))
        return 1
    log.info("  States     : %s", ", ".join(selected))

    # Init: bring DUT to a testable (awake, online) state before the first cycle (FWK031).
    relay = None
    if args.pin:
        relay = RelayController(pin=args.pin, active_low=config.RELAY_ACTIVE_LOW,
                                mode=config.GPIO_MODE, dry_run=args.dry_run)
    try:
        ok, method = function.init_dut(
            checker, relay, args.type,
            boot_timeout=args.wake_timeout, off_time=0,
            short_press_sec=config.ATX_SHORT_PRESS_SEC,
            force_off_sec=config.ATX_LONG_PRESS_SEC,
            init_wait=args.init_wait, dry_run=args.dry_run,
        )
    finally:
        if relay is not None:
            relay.cleanup()
    if not ok:
        log.error("Init failed (method=%s) - cannot start sleep test.", method)
        return 1
    log.info("Init OK (method=%s) - starting test.", method)

    # Run each selected state as its own session/report.
    verdicts = {}
    for state in selected:
        if _stop_requested:
            break
        verdicts[state] = run_state(state, args, checker, out_dir)

    log.info("=" * 50)
    for state, v in verdicts.items():
        log.info("  %s : %s", state, v)
    overall_ok = all(v == PASS for v in verdicts.values()) and len(verdicts) > 0
    log.info("OVERALL: %s", "PASS" if overall_ok else "FAIL")

    # Restore DUT test-environment settings (reverses setup_dut.sh changes).
    if not _stop_requested and args.ssh_user:
        function.restore_dut_env(args.host, args.port, args.ssh_user)

    return 0 if overall_ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
