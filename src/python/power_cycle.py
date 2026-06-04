#!/usr/bin/env python3
# power_cycle.py — ATX / AT PSU power cycle test runner
#
# Usage:
#   python power_cycle.py [options]
#
# Options (all optional; defaults come from config.py):
#   --type    ATX|AT          PSU type
#   --host    IP_OR_HOST      DUT IP/hostname for liveness checks
#   --port    N               TCP port for liveness check (default 22)
#   --cycles  N               number of boot cycles
#   --on      SECONDS         DUT on-time per cycle
#   --off     SECONDS         wait time after power-off
#   --pin     BOARD_PIN       GPIO board pin number
#   --out     DIR             output directory for logs & reports
#   --report  DIR             report directory (default same as --out)
#   --no-check                skip network liveness checks
#   --dry-run                 run logic without touching GPIO (for testing)
#   --warmup  N               initialization cycles before the counted test begins (default: 1)
#   --boot-timeout SECONDS    max wait for DUT to come online (default: 120)
#   --ssh-user USERNAME       SSH login for graceful OS shutdown (default: none, use ATX press)
#   --new-session             force a new session instead of resuming an incomplete one (LOG023)
#
# Verdicts per cycle:
#   PASS            — boot OK, ran full ON_TIME, shut down cleanly
#   NO_BOOT         — DUT did not come online within BOOT_TIMEOUT
#   CRASH           — DUT went offline during ON_TIME
#   HANG_SHUTDOWN   — DUT still responding after DEAD_TIMEOUT post power-off
#   RELAY_ERROR     — GPIO/relay operation raised an exception

import argparse
import logging
import os
import signal
import sys
import time
from pathlib import Path

import config
import function
from liveness import LivenessChecker
from relay import RelayController
from report import generate_report
from shutdown import ShutdownCoordinator

log = logging.getLogger("power_cycle")

# ── verdicts ─────────────────────────────────────────────────────────────────
PASS           = "PASS"
NO_BOOT        = "NO_BOOT"
CRASH          = "CRASH"
HANG_SHUTDOWN  = "HANG_SHUTDOWN"
RELAY_ERROR    = "RELAY_ERROR"

# ── global state (for signal handler) ────────────────────────────────────────
_stop_requested = False


def _sigint_handler(sig, frame):
    global _stop_requested
    print("\n[!] Ctrl-C received — finishing current cycle then stopping …")
    _stop_requested = True


# ── argument parsing ──────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Power cycle test (ATX / AT PSU)")
    p.add_argument("--type",     default=config.POWER_TYPE,
                   choices=["ATX", "AT"], help="PSU type (default: %(default)s)")
    p.add_argument("--host",     default=config.DUT_HOST,
                   help="DUT IP or hostname for liveness checks")
    p.add_argument("--port",     default=config.DUT_PORT, type=int,
                   help="TCP port to probe (default: %(default)s)")
    p.add_argument("--cycles",   default=config.CYCLES, type=int,
                   help="Number of boot cycles (default: %(default)s)")
    p.add_argument("--on",       default=config.ON_TIME_SEC, type=int,
                   dest="on_time", help="DUT on-time in seconds (default: %(default)s)")
    p.add_argument("--off",      default=config.OFF_TIME_SEC, type=int,
                   dest="off_time", help="Off-time between cycles in seconds (default: %(default)s)")
    p.add_argument("--pin",      default=config.GPIO_PIN, type=int,
                   help="GPIO BOARD pin number (default: %(default)s)")
    p.add_argument("--out",      default=config.LOG_DIR,
                   help="Output directory for logs (default: %(default)s)")
    p.add_argument("--report",   default=None,
                   help="Report directory (default: same as --out)")
    p.add_argument("--no-check", action="store_true",
                   help="Disable network liveness checks")
    p.add_argument("--dry-run",  action="store_true",
                   help="Simulate relay without touching GPIO")
    p.add_argument("--warmup",  default=config.WARMUP_CYCLES, type=int,
                   help="Initialization cycles before counted test (default: %(default)s)")
    p.add_argument("--boot-timeout", default=config.BOOT_TIMEOUT_SEC, type=int,
                   dest="boot_timeout",
                   help="Max seconds waiting for DUT to boot (default: %(default)s)")
    p.add_argument("--dut-os",   default="auto",
                   choices=["auto", "windows", "linux"], dest="dut_os",
                   help="DUT operating system: auto (probe via SSH), windows, or linux. "
                        "Selects the default SSH shutdown command. (default: %(default)s)")
    p.add_argument("--ssh-user", default=config.SHUTDOWN_SSH_USER,
                   dest="ssh_user",
                   help="SSH username for graceful shutdown (empty = skip SSH method)")
    p.add_argument("--ssh-cmd",  default=None,
                   dest="ssh_cmd",
                   help="Shutdown command to run over SSH "
                        "(default: OS-appropriate command selected by --dut-os)")
    p.add_argument("--max-consecutive-fails", default=config.MAX_CONSECUTIVE_FAILS, type=int,
                   dest="max_consecutive_fails",
                   help="Abort after N consecutive failed cycles; 0 = never abort "
                        "(default: %(default)s)")
    p.add_argument("--new-session", action="store_true", dest="new_session",
                   help="Force a new session even if an incomplete one exists (LOG023)")
    return p.parse_args()


# ── one cycle ─────────────────────────────────────────────────────────────────

def run_one_cycle(
    n: int,
    args: argparse.Namespace,
    relay: RelayController,
    checker,                        # LivenessChecker | None
    shutdown_coord: ShutdownCoordinator = None,
    total: int = 0,                 # total cycles in this phase (for log label)
    is_warmup: bool = False,
) -> dict:
    """Execute one power cycle and return a cycle-record dict."""
    rec = {
        "n":                n,
        "t_start":          function.now_iso(),
        "t_power_on":       None,
        "t_alive":          None,
        "boot_time_sec":    None,
        "t_power_off":      None,
        "t_dead":           None,
        "shutdown_time_sec": None,
        "shutdown_method":  None,
        "verdict":          RELAY_ERROR,
        "notes":            "",
    }

    _total = total or args.cycles
    if is_warmup:
        log.info("[WARMUP %d/%d] ──────────────────────────────────────", n, _total)
    else:
        log.info("─── Cycle %d / %d ───────────────────────────────", n, _total)

    # ── 1. Power ON ──────────────────────────────────────────────────────
    try:
        rec["t_power_on"] = function.now_iso()
        if args.type == "ATX":
            relay.atx_press(config.ATX_SHORT_PRESS_SEC)
        else:
            relay.at_power_on()
    except Exception as exc:
        rec["notes"] = f"relay error on power-on: {exc}"
        log.error("Relay error during power-on: %s", exc)
        return rec

    # ── 2. Wait for DUT to boot ───────────────────────────────────────────
    if checker:
        ok, boot_t = checker.wait_until_alive(args.boot_timeout)
        rec["t_alive"] = function.now_iso()
        rec["boot_time_sec"] = round(boot_t, 2)

        if not ok:
            rec["verdict"] = NO_BOOT
            rec["notes"]   = f"DUT did not come online within {args.boot_timeout}s"
            log.warning("Cycle %d: NO_BOOT", n)
            # Ensure DUT is actually off before next cycle
            _force_off(args, relay)
            return rec

        log.info("Cycle %d: DUT alive in %.1f s", n, boot_t)
    else:
        log.info("Cycle %d: liveness check disabled — sleeping %d s for boot", n, 30)
        time.sleep(30)     # Blind wait when no-check is used
        rec["t_alive"] = function.now_iso()

    # ── 3. Keep DUT on for ON_TIME, with periodic health checks ───────────
    crash_detected = False
    on_deadline = time.monotonic() + args.on_time
    next_check   = time.monotonic() + config.HEALTH_CHECK_INTERVAL

    while time.monotonic() < on_deadline:
        if _stop_requested:
            break
        if checker and time.monotonic() >= next_check:
            if not checker.is_alive():
                rec["verdict"] = CRASH
                rec["notes"]   = "DUT stopped responding during ON_TIME"
                log.warning("Cycle %d: CRASH — DUT offline during ON_TIME", n)
                crash_detected = True
                break
            next_check = time.monotonic() + config.HEALTH_CHECK_INTERVAL
        time.sleep(1)

    if crash_detected:
        _force_off(args, relay)
        return rec

    # ── 4. Shutdown (SSH -> ATX soft -> force-off -> time-based) ─────────
    rec["t_power_off"] = function.now_iso()
    sd = shutdown_coord.request()
    rec["shutdown_method"]   = sd["method"]
    rec["t_dead"]            = function.now_iso()
    rec["shutdown_time_sec"] = sd["elapsed_sec"]

    if not sd["success"]:
        rec["verdict"] = HANG_SHUTDOWN
        rec["notes"]   = (
            f"Shutdown via {sd['method']} timed out "
            f"(force_used={sd['force_used']})"
        )
        log.warning("Cycle %d: HANG_SHUTDOWN (method=%s)", n, sd["method"])
        return rec

    # ── 6. OFF_TIME wait ─────────────────────────────────────────────────
    log.info("Cycle %d: PASS — waiting %ds before next cycle …", n, args.off_time)
    rec["verdict"] = PASS

    off_deadline = time.monotonic() + args.off_time
    while time.monotonic() < off_deadline and not _stop_requested:
        time.sleep(1)

    return rec


def _force_off(args: argparse.Namespace, relay: RelayController) -> None:
    """Best-effort force power off before next cycle."""
    try:
        if args.type == "ATX":
            relay.atx_force_off(config.ATX_LONG_PRESS_SEC)
        else:
            relay.at_power_off()
        time.sleep(config.OFF_TIME_SEC)
    except Exception as exc:
        log.error("Force-off error: %s", exc)


# ── summary helpers ───────────────────────────────────────────────────────────

def _build_summary(cycles: list, target: int) -> dict:
    verdicts = [c["verdict"] for c in cycles]
    fail_breakdown = {
        NO_BOOT:       verdicts.count(NO_BOOT),
        CRASH:         verdicts.count(CRASH),
        HANG_SHUTDOWN: verdicts.count(HANG_SHUTDOWN),
        RELAY_ERROR:   verdicts.count(RELAY_ERROR),
    }
    total_fail = sum(fail_breakdown.values())
    total_pass = verdicts.count(PASS)
    return {
        "cycles_target": target,
        "total_ran":     len(cycles),
        "pass":          total_pass,
        "fail":          total_fail,
        "fail_breakdown": fail_breakdown,
    }


# ── result structure ──────────────────────────────────────────────────────────

def _new_result(args: argparse.Namespace, session_id: str, m: int) -> dict:
    """Build a fresh result.json structure for a new session."""
    return {
        "schema_version": "1.1",
        "test_name":      "power_cycle",
        "session_id":     session_id,
        "started_at":     function.now_iso(),
        "ended_at":       None,
        "config": {
            "power_type":       args.type,
            "dut_host":         args.host,
            "dut_port":         args.port,
            "cycles_target":    m,
            "on_time_sec":      args.on_time,
            "off_time_sec":     args.off_time,
            "boot_timeout_sec": args.boot_timeout,
            "dead_timeout_sec": config.DEAD_TIMEOUT_SEC,
            "warmup_cycles":    args.warmup,
            "ssh_user":         args.ssh_user or None,
        },
        "cycles":          [],
        "summary":         {},
        "overall_verdict": "RUNNING",
    }


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    args = parse_args()
    if args.report is None:
        args.report = args.out

    out_dir = Path(args.out)
    rep_dir = Path(args.report)
    out_dir.mkdir(parents=True, exist_ok=True)
    rep_dir.mkdir(parents=True, exist_ok=True)

    # ── Session resolution (LOG023) ────────────────────────────────────────────
    session_path = out_dir / "power_cycle_session.json"
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
            "session_id": session_id,
            "test":       "power_cycle",
            "m":          m,
            "n":          0,
            "status":     "running",
            "started_at": function.now_iso(),
            "updated_at": function.now_iso(),
        }
        function.write_json(str(session_path), session)

    # Paths derived from session_id; a resumed run reuses the same files.
    stem      = f"power_cycle_{session_id}"
    log_path  = out_dir / f"{stem}.log"
    json_path = out_dir / f"{stem}.result.json"
    html_path = rep_dir / f"power_cycle_report_{session_id}.html"

    function.setup_logging(str(log_path))   # FileHandler appends on resume
    signal.signal(signal.SIGINT, _sigint_handler)

    log.info("Power Cycle Test")
    log.info("  Session : %s%s", session_id, "  (RESUMING)" if resuming else "")
    log.info("  Type    : %s",     args.type)
    log.info("  Host    : %s",     args.host or "(liveness disabled)")
    log.info("  Cycles  : m=%d, starting at n=%d", m, start_n)
    log.info("  On/Off  : %ds / %ds", args.on_time, args.off_time)
    log.info("  GPIO pin: %d",     args.pin)
    log.info("  Warmup  : %d cycle(s)%s", args.warmup,
             "  (skipped on resume)" if resuming else "")
    log.info("  Boot TO : %ds",    args.boot_timeout)
    log.info("  SSH user: %s",     args.ssh_user or "(none — ATX relay only)")
    log.info("  Log     : %s",     log_path)
    log.info("  JSON    : %s",     json_path)
    log.info("  Report  : %s",     html_path)

    if resuming and args.cycles != m and args.cycles != config.CYCLES:
        log.warning("Requested --cycles %d differs from resumed session m=%d; using %d",
                    args.cycles, m, m)

    if args.dry_run:
        log.info("  *** DRY-RUN mode — GPIO will NOT be touched ***")

    # Relay
    relay = RelayController(
        pin=args.pin,
        active_low=config.RELAY_ACTIVE_LOW,
        mode=config.GPIO_MODE,
        dry_run=args.dry_run,
    )

    # Liveness checker (None if disabled or no host)
    checker = None
    if not args.no_check and args.host:
        checker = LivenessChecker(
            host=args.host,
            port=args.port,
            ping_count=config.PING_COUNT,
            ping_timeout=config.PING_TIMEOUT_SEC,
            tcp_timeout=config.TCP_TIMEOUT_SEC,
        )
    elif not args.host:
        log.warning("DUT_HOST is not set — liveness checks disabled")

    # Resolve DUT OS: probe via SSH when "auto", then pick the right shutdown command.
    if args.dut_os == "auto":
        if args.dry_run or args.no_check or not args.ssh_user or not args.host:
            args.dut_os = config.DUT_OS
        else:
            detected = function.detect_dut_os(args.host, args.port, args.ssh_user)
            args.dut_os = detected if detected != "unknown" else config.DUT_OS

    shutdown_cmd = args.ssh_cmd or config._OS_SHUTDOWN_CMD.get(args.dut_os,
                                                                "shutdown /s /t 5")

    # Shutdown coordinator (constructed once; reused every cycle)
    shutdown_coord = ShutdownCoordinator(
        relay=relay,
        checker=checker,
        psu_type=args.type,
        ssh_user=args.ssh_user,
        ssh_host=args.host,
        ssh_port=args.port,
        dead_timeout_sec=config.DEAD_TIMEOUT_SEC,
        time_based_delay_sec=args.off_time,
        ssh_cmd=shutdown_cmd,
    )

    # Build or load result structure (resume reuses the existing file)
    if resuming:
        result = function.read_json(str(json_path)) or _new_result(args, session_id, m)
        # Crash safety: drop any cycle records past the last committed session n
        # (result.json is written before session.json, so an orphan can exist).
        result["cycles"] = result.get("cycles", [])[: session["n"]]
        log.info("Resuming session %s: %d of %d cycles already recorded",
                 session_id, len(result["cycles"]), m)
    else:
        result = _new_result(args, session_id, m)

    # ── Initial state normalization ───────────────────────────────────────────
    # If DUT is already alive when the test starts (e.g. left on after setup_dut),
    # force it off first so every test begins from a known OFF state.
    if checker and checker.is_alive():
        log.info("DUT is alive at test start — forcing off to establish known state ...")
        _force_off(args, relay)

    # ── Warmup cycles (new session only) ──────────────────────────────────────
    if args.warmup > 0 and not resuming:
        log.info("=== Warmup: %d cycle(s) before counted test ===", args.warmup)
        for w in range(1, args.warmup + 1):
            rec = run_one_cycle(w, args, relay, checker, shutdown_coord,
                                total=args.warmup, is_warmup=True)
            log.info("[WARMUP %d/%d] verdict: %s (not counted)", w, args.warmup, rec["verdict"])
        log.info("=== Warmup complete — starting counted cycle(s) ===")

    consecutive_fails = 0
    last_n = start_n - 1

    try:
        for n in range(start_n, m + 1):
            if _stop_requested:
                log.info("Stop requested — exiting loop after cycle %d", n - 1)
                break

            rec = run_one_cycle(n, args, relay, checker, shutdown_coord, total=m)
            result["cycles"].append(rec)
            last_n = n

            # Track consecutive failures
            if rec["verdict"] == PASS:
                consecutive_fails = 0
            else:
                consecutive_fails += 1
                if args.max_consecutive_fails > 0:
                    log.warning(
                        "Consecutive fails: %d / %d",
                        consecutive_fails,
                        args.max_consecutive_fails,
                    )
                if (args.max_consecutive_fails > 0
                        and consecutive_fails >= args.max_consecutive_fails):
                    log.error(
                        "Reached %d consecutive failures — aborting test.",
                        args.max_consecutive_fails,
                    )
                    break

            # Persist JSON after every cycle (atomic write)
            result["summary"] = _build_summary(result["cycles"], m)
            result["overall_verdict"] = "RUNNING"
            function.write_result_json(str(json_path), result)

            # Persist session progress after every cycle (atomic write, LOG023)
            session["n"] = n
            session["updated_at"] = function.now_iso()
            function.write_json(str(session_path), session)

    finally:
        relay.cleanup()

    # Mark session complete if all cycles ran; otherwise leave it resumable.
    if last_n >= m and not _stop_requested:
        session["status"] = "complete"
    session["n"] = last_n
    session["updated_at"] = function.now_iso()
    function.write_json(str(session_path), session)

    # Finalise
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
    log.info("Result JSON: %s", json_path)

    # Generate HTML report
    generate_report(result, str(html_path))
    log.info("HTML report: %s", html_path)

    # Print final summary
    s = result["summary"]
    log.info("=" * 50)
    log.info("RESULT:  %s", result["overall_verdict"])
    log.info("Total ran : %d / %d", s["total_ran"], s["cycles_target"])
    log.info("Pass      : %d", s["pass"])
    log.info("Fail      : %d  (NO_BOOT=%d  CRASH=%d  HANG_SHUTDOWN=%d  RELAY_ERROR=%d)",
             s["fail"],
             s["fail_breakdown"][NO_BOOT],
             s["fail_breakdown"][CRASH],
             s["fail_breakdown"][HANG_SHUTDOWN],
             s["fail_breakdown"][RELAY_ERROR])
    log.info("=" * 50)

    return 0 if result["overall_verdict"] == PASS else 1


if __name__ == "__main__":
    sys.exit(main())
