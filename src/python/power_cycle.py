#!/usr/bin/env python3
# power_cycle.py — ATX / AT PSU power cycle test runner
#
# Usage:
#   python power_cycle.py [options]
#
# All options are optional; defaults come from config.py.  Set DUT_HOST,
# SHUTDOWN_SSH_USER, and DUT_OS there once so you can run without arguments.
#
# Quick-start by OS:
#   Windows DUT  →  python power_cycle.py --host <IP>
#                   (ATX short-press handles both power-on and power-off)
#
#   Linux DUT    →  python power_cycle.py --host <IP> --ssh-user <login>
#                   (ATX short-press powers ON; SSH "sudo shutdown -h now" powers OFF)
#                   Without --ssh-user on Linux, GNOME intercepts the ATX press and
#                   shows an interactive dialog → HANG_SHUTDOWN every cycle.
#                   Tip: set SHUTDOWN_SSH_USER = "<login>" in config.py so you
#                   don't need to pass --ssh-user each run.
#
# Key options:
#   --type    ATX|AT          PSU type
#   --host    IP_OR_HOST      DUT IP/hostname for liveness checks
#   --port    N               TCP port for liveness check (default 22)
#   --cycles  N               number of boot cycles
#   --on      SECONDS         DUT on-time per cycle
#   --off     SECONDS         wait time after power-off
#   --pin     BOARD_PIN       GPIO board pin number
#   --ssh-user USERNAME       SSH login for graceful OS shutdown (required for Linux DUT)
#   --out     DIR             output directory for logs & reports
#   --no-check                skip network liveness checks
#   --dry-run                 run logic without touching GPIO (for testing)
#   --warmup  N               initialization cycles before the counted test begins (default: 1)
#   --boot-timeout SECONDS    max wait for DUT to come online (default: 120)
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
                   help="Boot ceiling for the main counted test in seconds. "
                        "Overridden by auto-calibration when --calibrate > 0. "
                        "(default: %(default)s)")
    p.add_argument("--boot-ceiling", default=config.BOOT_CEILING_SEC, type=int,
                   dest="boot_ceiling",
                   help="Absolute maximum boot wait for the calibration phase and hard "
                        "fallback when calibration is disabled. "
                        "Any platform not alive within this limit is NO_BOOT. "
                        "(default: %(default)s)")
    p.add_argument("--calibrate", default=config.CALIBRATE_CYCLES, type=int,
                   dest="calibrate_cycles",
                   help="Calibration cycles to run after warmup (0 = disabled). "
                        "Measures actual boot time and auto-sets --boot-timeout for the "
                        "main test as max(observed) × %.1f. (default: %%(default)s)"
                        % config.CALIBRATE_SAFETY_FACTOR)
    p.add_argument("--dut-os",   default="auto",
                   choices=["auto", "windows", "linux"], dest="dut_os",
                   help="DUT operating system: auto (probe via SSH), windows, or linux. "
                        "Selects the default SSH shutdown command. (default: %(default)s)")
    p.add_argument("--ssh-user", default=config.SHUTDOWN_SSH_USER,
                   dest="ssh_user",
                   help="SSH login for graceful shutdown via 'sudo shutdown -h now'. "
                        "REQUIRED for Linux DUT with GNOME desktop — without it, "
                        "the ATX power-button press is intercepted by GNOME and causes "
                        "HANG_SHUTDOWN every cycle. "
                        "Windows DUT: leave empty to use ATX press for shutdown. "
                        "(default from config.SHUTDOWN_SSH_USER)")
    p.add_argument("--ssh-cmd",  default=None,
                   dest="ssh_cmd",
                   help="Shutdown command to run over SSH "
                        "(default: OS-appropriate command selected by --dut-os)")
    p.add_argument("--early-fail-threshold", default=config.EARLY_FAIL_THRESHOLD, type=int,
                   dest="early_fail_threshold",
                   help="Abort if first N cycles all fail before any PASS; 0 = never "
                        "(default: %(default)s)")
    p.add_argument("--max-consecutive-fails", default=config.MAX_CONSECUTIVE_FAILS, type=int,
                   dest="max_consecutive_fails",
                   help="Abort after N consecutive mid-run failures; 0 = never abort "
                        "(default: %(default)s)")
    p.add_argument("--leave-on", action="store_true", dest="leave_on",
                   help="Skip the shutdown step on the last cycle, leaving the DUT powered on. "
                        "Use before running reboot.py so it finds the DUT already online.")
    p.add_argument("--new-session", action="store_true", dest="new_session",
                   help="Force a new session even if an incomplete one exists (LOG023)")
    p.add_argument("--debug", action="store_true", dest="debug",
                   help="Stop immediately on the FIRST non-PASS cycle in any phase "
                        "(warmup/calibrate/main), without forcing the relay off — "
                        "preserves the DUT/relay state as-is for inspection. "
                        "Overrides --early-fail-threshold / --max-consecutive-fails.")
    return p.parse_args()


# ── OS re-detection ────────────────────────────────────────────────────────────

def _redetect_os_if_needed(rec, args, shutdown_coord, result, label):
    """Re-probe DUT OS while it is confirmed alive, if the startup probe never
    confirmed it.

    main() probes the OS via SSH before the DUT is ever powered on, so on a
    freshly-off DUT the probe always fails (exit 255, nothing listening) and
    dut_os_source falls back to "assumed" for the whole run -- the wrong
    (linux) shutdown command then gets sent to e.g. a Windows DUT every cycle,
    even though SSH credentials are perfectly valid (see BUG0030's follow-up).
    This runs from inside run_one_cycle right after the DUT is confirmed alive
    (so SSH actually answers), updating dut_os / dut_os_source /
    shutdown_coord.ssh_cmd for the remainder of the run.
    """
    # Only redetect an unverified guess. "detected" (startup probe succeeded)
    # and "explicit" (--dut-os) are already trustworthy -- re-probing them just
    # adds a useless SSH round-trip and, run post-shutdown, a spurious
    # "exit 255, host offline" warning every cycle.
    if args.dut_os_source != "assumed":
        return
    if getattr(args, "_os_redetect_done", False):
        return
    if not rec.get("t_alive") or rec.get("verdict") == NO_BOOT:
        return
    if args.dry_run or args.no_check or not args.ssh_user or not args.host:
        return

    detected = function.detect_dut_os(args.host, args.port, args.ssh_user)
    if detected == "unknown":
        return  # SSH not up yet despite liveness -- try again next cycle

    args._os_redetect_done = True
    if detected != args.dut_os:
        log.info(
            "%s: DUT now reachable -- re-detected OS as '%s' (was assumed '%s'); "
            "updating shutdown command for the rest of the run.",
            label, detected, args.dut_os,
        )
        args.dut_os = detected
        shutdown_coord.ssh_cmd = args.ssh_cmd or config._OS_SHUTDOWN_CMD.get(
            detected, "shutdown /s /t 5")
        result["config"]["dut_os"] = detected

    args.dut_os_source = "detected"
    result["config"]["dut_os_source"] = "detected"


# ── one cycle ─────────────────────────────────────────────────────────────────

def run_one_cycle(
    n: int,
    args: argparse.Namespace,
    relay: RelayController,
    checker,                        # LivenessChecker | None
    shutdown_coord: ShutdownCoordinator = None,
    total: int = 0,                 # total cycles in this phase (for log label)
    is_warmup: bool = False,
    leave_on: bool = False,         # skip shutdown on this cycle (--leave-on on last cycle)
    result: dict = None,            # run result, for in-cycle OS re-detection
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
            if args.debug:
                log.error("Cycle %d: --debug active — leaving relay/DUT state as-is "
                           "for inspection (NOT forcing off)", n)
            else:
                # Ensure DUT is actually off before next cycle
                _force_off(args, relay)
            return rec

        log.info("Cycle %d: DUT alive in %.1f s", n, boot_t)
        # DUT is up and SSH answers now -- confirm the OS here if the startup
        # probe couldn't (DUT was off then), so the shutdown step below uses the
        # right command instead of an unverified "assumed" guess.
        if shutdown_coord is not None and result is not None:
            _redetect_os_if_needed(rec, args, shutdown_coord, result, f"Cycle {n}")
        function.notify_dut(
            args.ssh_user, args.host, args.port,
            f"Power cycle test in progress - cycle {n}/{_total}. Do not use.",
            dry_run=args.dry_run,
            dut_os=args.dut_os,
        )
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
        if args.debug:
            log.error("Cycle %d: --debug active — leaving relay/DUT state as-is "
                       "for inspection (NOT forcing off)", n)
        else:
            _force_off(args, relay)
        return rec

    # ── 4. Shutdown (SSH -> ATX soft -> force-off -> time-based) ─────────
    if leave_on:
        log.info("Cycle %d: PASS (--leave-on: skipping shutdown, DUT left powered on)", n)
        rec["verdict"] = PASS
        return rec

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
        if args.debug:
            log.error("Cycle %d: --debug active — stopping without further relay "
                       "action for inspection", n)
            return rec
        # force-off was already applied inside shutdown_coord; wait off_time so
        # the next cycle's power-on has adequate settling time after force-off.
        if args.off_time > 0 and not _stop_requested:
            log.info("Cycle %d: waiting %ds off-time after force-off ...", n, args.off_time)
            off_deadline = time.monotonic() + args.off_time
            while time.monotonic() < off_deadline and not _stop_requested:
                time.sleep(1)
        return rec

    # ── 6. OFF_TIME wait ─────────────────────────────────────────────────
    log.info("Cycle %d: PASS — waiting %ds before next cycle …", n, args.off_time)
    rec["verdict"] = PASS

    off_deadline = time.monotonic() + args.off_time
    while time.monotonic() < off_deadline and not _stop_requested:
        time.sleep(1)

    return rec


def _run_calibrate_phase(
    args: argparse.Namespace,
    relay: RelayController,
    checker,
    shutdown_coord: ShutdownCoordinator,
    result: dict,
) -> bool:
    """Run calibrate cycles to measure actual boot time, then update args.boot_timeout.

    Each calibrate cycle: power on → wait alive (ceiling) → shutdown immediately.
    After all cycles, boot_timeout = max(observed) × CALIBRATE_SAFETY_FACTOR,
    capped at boot_ceiling.  Result is stored in result["calibrate"] for the report.
    Calibrate cycles are NOT counted in the main summary.

    Returns True if --debug stopped the phase early on a non-PASS cycle (the
    caller must then skip the main loop, leaving DUT/relay state untouched).
    """
    import copy
    n_cal = args.calibrate_cycles
    log.info("=== Calibrate: %d cycle(s) — measuring boot time (ceiling %ds) ===",
             n_cal, args.boot_ceiling)

    # Temporary args: ceiling for boot, minimal on_time so we shut down right away
    cal_args = copy.copy(args)
    cal_args.boot_timeout = args.boot_ceiling
    cal_args.on_time      = 5  # just enough for the DUT to settle before shutdown

    boot_times = []
    for c in range(1, n_cal + 1):
        if _stop_requested:
            break
        log.info("[CAL %d/%d] ──────────────────────────────────────", c, n_cal)
        rec = run_one_cycle(c, cal_args, relay, checker, shutdown_coord,
                            total=n_cal, is_warmup=True, result=result)
        boot_t = rec.get("boot_time_sec")
        log.info("[CAL %d/%d] verdict: %s  boot: %s s",
                 c, n_cal, rec["verdict"],
                 f"{boot_t:.1f}" if boot_t and boot_t < args.boot_ceiling else "—")
        result["calibrate"]["cycles"].append({
            "n":            c,
            "verdict":      rec["verdict"],
            "boot_time_sec": boot_t,
        })
        if rec["verdict"] == PASS and boot_t and boot_t < args.boot_ceiling:
            boot_times.append(boot_t)
        if args.debug and rec["verdict"] != PASS:
            log.error("--debug: calibrate cycle %d failed (%s) — stopping immediately, "
                       "state left as-is for inspection.", c, rec["verdict"])
            return True

    if boot_times:
        computed = round(max(boot_times) * config.CALIBRATE_SAFETY_FACTOR)
        calibrated = min(computed, args.boot_ceiling)
        log.info(
            "=== Calibrate complete — boot times: min=%.1fs max=%.1fs "
            "→ boot_timeout set to %ds (max × %.1f, capped at %ds) ===",
            min(boot_times), max(boot_times),
            calibrated, config.CALIBRATE_SAFETY_FACTOR, args.boot_ceiling,
        )
        args.boot_timeout = calibrated
        result["calibrate"]["boot_timeout_sec"] = calibrated
        result["config"]["boot_timeout_sec"]    = calibrated
    else:
        log.warning(
            "=== Calibrate: no successful boots — keeping boot_timeout=%ds ===",
            args.boot_timeout,
        )
        result["calibrate"]["boot_timeout_sec"] = None

    return False


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

    # How each cycle was actually powered off (ssh = graceful OS shutdown,
    # atx = power-button press, force = held button, time = blind delay).
    # Cycles that never reached shutdown (NO_BOOT/CRASH) have method None and
    # are not counted here.
    methods = [c.get("shutdown_method") for c in cycles]
    shutdown_breakdown = {
        "ssh":   methods.count("ssh"),
        "atx":   methods.count("atx"),
        "force": methods.count("force"),
        "time":  methods.count("time"),
    }
    return {
        "cycles_target": target,
        "total_ran":     len(cycles),
        "pass":          total_pass,
        "fail":          total_fail,
        "fail_breakdown": fail_breakdown,
        "shutdown_breakdown": shutdown_breakdown,
    }


# ── result structure ──────────────────────────────────────────────────────────

def _new_result(args: argparse.Namespace, session_id: str, m: int,
                 dut_os_source: str = "explicit") -> dict:
    """Build a fresh result.json structure for a new session."""
    return {
        "schema_version": "1.3",
        "test_name":      "power_cycle",
        "session_id":     session_id,
        "started_at":     function.now_iso(),
        "ended_at":       None,
        "config": {
            "power_type":            args.type,
            "dut_host":              args.host,
            "dut_port":              args.port,
            "cycles_target":         m,
            "on_time_sec":           args.on_time,
            "off_time_sec":          args.off_time,
            "boot_timeout_sec":      args.boot_timeout,
            "boot_ceiling_sec":      args.boot_ceiling,
            "dead_timeout_sec":      config.DEAD_TIMEOUT_SEC,
            "warmup_cycles":         args.warmup,
            "calibrate_cycles":      args.calibrate_cycles,
            "ssh_user":              args.ssh_user or None,
            "dut_os":                args.dut_os,
            "dut_os_source":         dut_os_source,
            "debug_mode":            bool(args.debug),
        },
        "calibrate": {
            "cycles":            [],       # each calibrate cycle's boot_time_sec
            "boot_timeout_sec":  None,     # computed from calibrate; None if skipped
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
    # A resumed session must target the same DUT as the one that created it —
    # otherwise cycles from two different physical hosts get merged into one
    # result.json (e.g. a stale aborted session on host A silently "resuming"
    # hours later against host B). Identify the target by the same fields that
    # actually change DUT behaviour: host, port, ssh_user, type.
    target = {
        "host":     args.host or None,
        "port":     args.port,
        "ssh_user": args.ssh_user or None,
        "type":     args.type,
    }

    session_path = out_dir / "power_cycle_session.json"
    session = function.read_json(str(session_path))
    candidate_resume = bool(
        session
        and session.get("status") == "running"
        and session.get("n", 0) < session.get("m", 0)
        and not args.new_session
    )

    if candidate_resume and session.get("target") != target:
        log.error(
            "Refusing to resume session %s: target mismatch "
            "(session target=%s, current target=%s). "
            "Re-run with --host/--ssh-user/--type matching the original session, "
            "or pass --new-session to start a fresh one.",
            session.get("session_id"), session.get("target"), target,
        )
        return 1

    resuming = candidate_resume

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
            "target":     target,
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
    log.info("  Boot TO : %ds (ceiling %ds)",  args.boot_timeout, args.boot_ceiling)
    log.info("  SSH user: %s",     args.ssh_user or "(none — ATX relay only)")
    log.info("  Calibrate: %d cycle(s)%s",
             args.calibrate_cycles,
             " (skipped on resume)" if resuming else
             " (disabled — using --boot-timeout directly)" if args.calibrate_cycles == 0 else "")
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
    # Note: probing runs before warmup, so the DUT may still be off.  If SSH fails
    # (exit 255, connection refused), detect_dut_os() returns "unknown" and we fall
    # back to config.DUT_OS.  Set DUT_OS = "linux" in config.py so the fallback is
    # correct when the DUT is offline at startup.
    # dut_os_source records HOW args.dut_os was decided, so we never present a
    # blind guess (config.DUT_OS's default) with the same confidence as an
    # explicit --dut-os or a successful SSH probe. This matters because a
    # missing/incorrect --ssh-user makes the probe fail "unknown" -> falls
    # back to the config default, which used to be silently treated as fact
    # and triggered a misleading Linux-specific warning even on a Windows DUT.
    if args.dut_os == "auto":
        if args.dry_run or args.no_check or not args.ssh_user or not args.host:
            args.dut_os    = config.DUT_OS
            dut_os_source  = "assumed"
        else:
            detected = function.detect_dut_os(args.host, args.port, args.ssh_user)
            if detected != "unknown":
                args.dut_os   = detected
                dut_os_source = "detected"
            else:
                args.dut_os   = config.DUT_OS
                dut_os_source = "assumed"
    else:
        dut_os_source = "explicit"

    # Stored on args (not just a local var) so run_one_cycle's callers can read
    # and, via _redetect_os_if_needed(), update it once the DUT is reachable.
    args.dut_os_source = dut_os_source

    shutdown_cmd = args.ssh_cmd or config._OS_SHUTDOWN_CMD.get(args.dut_os,
                                                                "shutdown /s /t 5")

    if dut_os_source == "assumed":
        # OS is unconfirmed (no --ssh-user, --dut-os, or the SSH probe failed,
        # e.g. a wrong --ssh-user). Shutdown still works via the ATX button
        # regardless of OS, so this is informational, not the scary
        # Linux-specific guardrail below — that one requires confirmed OS.
        log.warning(
            "DUT OS not confirmed (no --ssh-user/--dut-os, or SSH probe failed) — "
            "assuming '%s' from config.DUT_OS for command selection only. "
            "Shutdown will use the ATX power button regardless. "
            "Pass --dut-os explicitly if this assumption is wrong.",
            args.dut_os,
        )
    elif args.dut_os == "linux" and not args.ssh_user and not args.dry_run:
        # Guardrail: Linux DUT without SSH user → ATX short-press is intercepted
        # by GNOME's endSessionDialog; DUT never shuts down within
        # dead_timeout_sec → every cycle ends HANG_SHUTDOWN. Only fires when the
        # OS is actually confirmed (detected or explicit --dut-os linux).
        log.error(
            "Linux DUT but --ssh-user is not set — ATX power-button press will be\n"
            "  intercepted by GNOME and cause HANG_SHUTDOWN every cycle.\n"
            "  Fix: set  SHUTDOWN_SSH_USER = \"<login>\"  in config.py\n"
            "       or pass  --ssh-user <login>  on the command line.\n"
            "  (setup_dut.sh already configured NOPASSWD sudo on the DUT.)"
        )

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
        debug=args.debug,
    )

    # Build or load result structure (resume reuses the existing file)
    if resuming:
        result = function.read_json(str(json_path)) or _new_result(args, session_id, m, dut_os_source)
        # Crash safety: drop any cycle records past the last committed session n
        # (result.json is written before session.json, so an orphan can exist).
        result["cycles"] = result.get("cycles", [])[: session["n"]]
        log.info("Resuming session %s: %d of %d cycles already recorded",
                 session_id, len(result["cycles"]), m)
    else:
        result = _new_result(args, session_id, m, dut_os_source)

    # ── Initial state normalization ───────────────────────────────────────────
    # If DUT is already alive when the test starts (e.g. left on after setup_dut),
    # force it off first so every test begins from a known OFF state.
    if checker and checker.is_alive():
        log.info("DUT is alive at test start — forcing off to establish known state ...")
        _force_off(args, relay)

    # debug_abort: set when --debug stops the run early in warmup/calibrate, so the
    # main loop (and anything after it) is skipped while finalization still runs —
    # the partial result.json/report and the untouched DUT/relay state are the point.
    debug_abort = False

    # ── Warmup cycles (new session only) ──────────────────────────────────────
    if args.warmup > 0 and not resuming:
        log.info("=== Warmup: %d cycle(s) before counted test ===", args.warmup)
        for w in range(1, args.warmup + 1):
            rec = run_one_cycle(w, args, relay, checker, shutdown_coord,
                                total=args.warmup, is_warmup=True, result=result)
            log.info("[WARMUP %d/%d] verdict: %s (not counted)", w, args.warmup, rec["verdict"])
            if args.debug and rec["verdict"] != PASS:
                log.error("--debug: warmup cycle %d failed (%s) — stopping immediately, "
                           "state left as-is for inspection.", w, rec["verdict"])
                debug_abort = True
                break
        log.info("=== Warmup complete ===")

    # ── Calibrate phase (new session only) ────────────────────────────────────
    # Measures DUT boot time and sets boot_timeout for the main test automatically.
    if not debug_abort and args.calibrate_cycles > 0 and not resuming and checker and not args.no_check:
        debug_abort = _run_calibrate_phase(args, relay, checker, shutdown_coord, result)
        function.write_result_json(str(json_path), result)  # persist calibrate data

    consecutive_fails = 0
    has_had_success   = any(c.get("verdict") == PASS
                            for c in result.get("cycles", []))
    last_n = start_n - 1

    try:
        for n in range(start_n, m + 1):
            if debug_abort:
                log.info("--debug stop already triggered in an earlier phase — "
                          "skipping the main loop entirely.")
                break
            if _stop_requested:
                log.info("Stop requested — exiting loop after cycle %d", n - 1)
                break

            is_last = (n == m) and not _stop_requested
            rec = run_one_cycle(n, args, relay, checker, shutdown_coord, total=m,
                                leave_on=(args.leave_on and is_last), result=result)
            result["cycles"].append(rec)
            last_n = n

            if rec["verdict"] == PASS:
                has_had_success   = True
                consecutive_fails = 0
            else:
                consecutive_fails += 1
                if args.debug:
                    log.error(
                        "--debug: cycle %d failed (%s) — stopping immediately, "
                        "state left as-is for inspection.", n, rec["verdict"])
                    debug_abort = True
                    break
                if not has_had_success:
                    # Early phase: no PASS yet — likely a config/setup problem.
                    if (args.early_fail_threshold > 0
                            and consecutive_fails >= args.early_fail_threshold):
                        log.error(
                            "First %d cycles all failed before any PASS — aborting. "
                            "Check relay wiring, DUT host, and GPIO pin.",
                            args.early_fail_threshold)
                        break
                else:
                    # Mid-run: hardware under test — only abort if explicitly configured.
                    if (args.max_consecutive_fails > 0
                            and consecutive_fails >= args.max_consecutive_fails):
                        log.warning("Consecutive fails: %d / %d",
                                    consecutive_fails, args.max_consecutive_fails)
                        log.error(
                            "Reached %d consecutive mid-run failures — aborting test.",
                            args.max_consecutive_fails)
                        break

            # Persist JSON after every cycle (atomic write)
            result["summary"] = _build_summary(result["cycles"], m)
            result["overall_verdict"] = "RUNNING"
            try:
                function.write_result_json(str(json_path), result)
            except OSError as exc:
                # All retries in write_json() exhausted — don't abort an endurance
                # run over a persistence hiccup; `result` still holds every cycle
                # recorded so far and gets re-written whole on the next iteration.
                log.warning("Cycle %d: result.json write failed (%s) — will retry "
                            "on next cycle", n, exc)

            # Persist session progress after every cycle (atomic write, LOG023)
            session["n"] = n
            session["updated_at"] = function.now_iso()
            try:
                function.write_json(str(session_path), session)
            except OSError as exc:
                log.warning("Cycle %d: session.json write failed (%s) — will retry "
                            "on next cycle", n, exc)

    finally:
        relay.cleanup()

    # Mark session complete if all cycles ran; otherwise leave it resumable.
    if last_n >= m and not _stop_requested:
        session["status"] = "complete"
    session["n"] = last_n
    session["updated_at"] = function.now_iso()
    function.write_json(str(session_path), session)

    # Restore DUT test-environment settings (reverses setup_dut.sh changes).
    # Skipped when no SSH user is configured (pure ATX-relay mode); manual
    # fallback: sudo ./setup_dut.sh --restore on the DUT.
    if session.get("status") == "complete" and args.ssh_user:
        function.restore_dut_env(args.host, args.port, args.ssh_user)

    # Finalise
    result["ended_at"] = function.now_iso()
    summary = _build_summary(result["cycles"], m)
    result["summary"] = summary
    if debug_abort:
        result["debug_stop"] = {
            "n":       last_n,
            "verdict": result["cycles"][-1]["verdict"] if result["cycles"] else None,
        }

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
    sb = s.get("shutdown_breakdown", {})
    log.info("Shutdown  : ssh=%d  atx=%d  force=%d  time=%d",
             sb.get("ssh", 0), sb.get("atx", 0),
             sb.get("force", 0), sb.get("time", 0))
    log.info("=" * 50)

    return 0 if result["overall_verdict"] == PASS else 1


if __name__ == "__main__":
    sys.exit(main())
