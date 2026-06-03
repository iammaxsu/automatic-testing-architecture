#!/usr/bin/env python3
# reboot.py — SSH-controlled software reboot endurance test (PWR012)
#
# Usage:
#   python reboot.py [options]
#
# Options (all optional; defaults come from config.py):
#   --host    IP_OR_HOST      DUT IP/hostname for liveness checks
#   --port    N               TCP port for liveness check (default 22)
#   --cycles  N               number of reboot cycles
#   --off     SECONDS         settle wait after DUT goes offline before polling for online
#   --out     DIR             output directory for logs & results
#   --no-check                skip network liveness checks (useful for dry-run)
#   --dry-run                 run logic without issuing SSH reboot
#   --boot-timeout SECONDS    max wait for DUT to come back online (default: 120)
#   --ssh-user USERNAME       SSH login for reboot command (required)
#   --ssh-cmd COMMAND         reboot command to run over SSH (default: "sudo reboot")
#   --new-session             force a new session instead of resuming an incomplete one (LOG023)
#
# Verdicts per cycle:
#   PASS      — DUT came back online within BOOT_TIMEOUT after reboot command
#   NO_BOOT   — DUT did not come back online within BOOT_TIMEOUT
#   SSH_ERROR — reboot command could not be sent (SSH unreachable before reboot)

import argparse
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import config
import function
from liveness import LivenessChecker
from report import generate_report

log = logging.getLogger("reboot")

# ── verdicts ──────────────────────────────────────────────────────────────────
PASS      = "PASS"
NO_BOOT   = "NO_BOOT"
SSH_ERROR = "SSH_ERROR"

# ── global state (for signal handler) ─────────────────────────────────────────
_stop_requested = False


def _sigint_handler(sig, frame):
    global _stop_requested
    print("\n[!] Ctrl-C received — finishing current cycle then stopping …")
    _stop_requested = True


# ── argument parsing ───────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Software reboot endurance test (SSH-controlled)")
    p.add_argument("--host",          default=config.DUT_HOST,
                   help="DUT IP or hostname (required for liveness checks)")
    p.add_argument("--port",          default=config.DUT_PORT, type=int,
                   help="TCP port to probe (default: %(default)s)")
    p.add_argument("--cycles",        default=config.CYCLES, type=int,
                   help="Number of reboot cycles (default: %(default)s)")
    p.add_argument("--off",           default=config.OFF_TIME_SEC, type=int,
                   dest="off_time",
                   help="Settle wait in seconds after DUT goes offline (default: %(default)s)")
    p.add_argument("--out",           default=config.LOG_DIR,
                   help="Output directory for logs (default: %(default)s)")
    p.add_argument("--no-check",      action="store_true",
                   help="Disable network liveness checks")
    p.add_argument("--dry-run",       action="store_true",
                   help="Simulate reboot without issuing SSH command")
    p.add_argument("--boot-timeout",  default=config.BOOT_TIMEOUT_SEC, type=int,
                   dest="boot_timeout",
                   help="Max seconds waiting for DUT to come back online (default: %(default)s)")
    p.add_argument("--ssh-user",      default=config.SHUTDOWN_SSH_USER,
                   dest="ssh_user",
                   help="SSH username for reboot command (required at runtime)")
    p.add_argument("--ssh-cmd",       default=config.REBOOT_SSH_CMD,
                   dest="ssh_cmd",
                   help="Reboot command to run over SSH (default: %(default)s)")
    p.add_argument("--new-session",   action="store_true", dest="new_session",
                   help="Force a new session even if an incomplete one exists (LOG023)")
    return p.parse_args()


# ── SSH reboot ─────────────────────────────────────────────────────────────────

def _ssh_reboot(args: argparse.Namespace, ssh_timeout: int = 10) -> bool:
    """Issue the reboot command over SSH. Returns True if the command was sent."""
    if args.dry_run:
        log.info("DRY-RUN: would SSH %s@%s and run: %s",
                 args.ssh_user, args.host, args.ssh_cmd)
        return True

    cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={ssh_timeout}",
        "-p", str(args.port),
        f"{args.ssh_user}@{args.host}",
        args.ssh_cmd,
    ]
    log.info("SSH reboot: %s@%s  cmd=%s", args.ssh_user, args.host, args.ssh_cmd)
    try:
        result = subprocess.run(
            cmd,
            timeout=ssh_timeout + 5,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        rc = result.returncode
        if rc == 0:
            return True
        # 255: SSH transport closed — the OS started shutting down before the
        # command could return cleanly. This is a normal "success" for sudo reboot.
        if rc == 255:
            log.info("SSH reboot: exit 255 — connection closed by remote (reboot initiated)")
            return True
        # Any other non-zero exit (1 = sudo permission denied, etc.) is a real
        # failure. Log stderr to help diagnose the cause.
        stderr_text = (result.stderr or b"").decode(errors="replace").strip()
        log.warning("SSH reboot command returned %d%s", rc,
                    f": {stderr_text}" if stderr_text else "")
        if rc == 1 and not stderr_text:
            log.warning("Exit 1 with no stderr often means sudo requires a password. "
                        "Fix: on the DUT run: "
                        "echo '%s ALL=(ALL) NOPASSWD: /sbin/reboot' "
                        "| sudo tee /etc/sudoers.d/reboot-nopasswd", args.ssh_user)
        return False
    except subprocess.TimeoutExpired:
        log.warning("SSH reboot timed out after %ds", ssh_timeout + 5)
        return False
    except Exception as exc:
        log.warning("SSH reboot error: %s", exc)
        return False


# ── one cycle ──────────────────────────────────────────────────────────────────

def run_one_cycle(
    n: int,
    total: int,
    args: argparse.Namespace,
    checker,                          # LivenessChecker | None
) -> dict:
    """Execute one reboot cycle and return a cycle-record dict."""
    rec = {
        "n":               n,
        "t_start":         function.now_iso(),
        "t_reboot_cmd":    None,
        "t_offline":       None,
        "t_online":        None,
        "boot_time_sec":   None,
        "verdict":         SSH_ERROR,
        "notes":           "",
    }

    log.info("─── Cycle %d / %d ───────────────────────────────", n, total)

    # ── 1. Issue SSH reboot ────────────────────────────────────────────────
    rec["t_reboot_cmd"] = function.now_iso()
    ok = _ssh_reboot(args)
    if not ok:
        rec["notes"] = "SSH reboot command failed (DUT unreachable or SSH error)"
        log.warning("Cycle %d: SSH_ERROR", n)
        return rec

    # Small settle: give OS time to begin reboot before we poll for offline.
    if not args.dry_run:
        time.sleep(config.REBOOT_SETTLE_SEC)

    # ── 2. Wait for DUT to go offline ─────────────────────────────────────
    if checker and not args.dry_run:
        dead, offline_elapsed = checker.wait_until_dead(config.DEAD_TIMEOUT_SEC)
        rec["t_offline"] = function.now_iso()
        if not dead:
            log.warning("Cycle %d: DUT did not go offline within %ds after reboot",
                        n, config.DEAD_TIMEOUT_SEC)
    else:
        rec["t_offline"] = function.now_iso()

    # Optional settle after offline before polling for online.
    if args.off_time > 0 and not args.dry_run:
        time.sleep(args.off_time)

    # ── 3. Wait for DUT to come back online ───────────────────────────────
    if checker and not args.dry_run:
        alive, boot_t = checker.wait_until_alive(args.boot_timeout)
        rec["t_online"]      = function.now_iso()
        rec["boot_time_sec"] = round(boot_t, 2)

        if not alive:
            rec["verdict"] = NO_BOOT
            rec["notes"]   = f"DUT did not come back online within {args.boot_timeout}s"
            log.warning("Cycle %d: NO_BOOT (timeout %ds)", n, args.boot_timeout)
            return rec

        log.info("Cycle %d: DUT back online in %.1f s", n, boot_t)
    else:
        rec["t_online"] = function.now_iso()
        log.info("Cycle %d: liveness check disabled", n)

    rec["verdict"] = PASS
    return rec


# ── summary helpers ────────────────────────────────────────────────────────────

def _build_summary(cycles: list, target: int) -> dict:
    verdicts = [c["verdict"] for c in cycles]
    fail_breakdown = {
        NO_BOOT:   verdicts.count(NO_BOOT),
        SSH_ERROR: verdicts.count(SSH_ERROR),
    }
    return {
        "cycles_target": target,
        "total_ran":     len(cycles),
        "pass":          verdicts.count(PASS),
        "fail":          sum(fail_breakdown.values()),
        "fail_breakdown": fail_breakdown,
    }


def _new_result(args: argparse.Namespace, session_id: str, m: int) -> dict:
    return {
        "schema_version": "1.1",
        "test_name":      "reboot",
        "session_id":     session_id,
        "started_at":     function.now_iso(),
        "ended_at":       None,
        "config": {
            "dut_host":         args.host,
            "dut_port":         args.port,
            "cycles_target":    m,
            "off_time_sec":     args.off_time,
            "boot_timeout_sec": args.boot_timeout,
            "dead_timeout_sec": config.DEAD_TIMEOUT_SEC,
            "ssh_user":         args.ssh_user or None,
            "ssh_cmd":          args.ssh_cmd,
        },
        "cycles":          [],
        "summary":         {},
        "overall_verdict": "RUNNING",
    }


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> int:
    args = parse_args()

    if not args.ssh_user and not args.dry_run and not args.no_check:
        print("ERROR: --ssh-user is required for reboot.py (no relay fallback).")
        print("       Use --dry-run to test without a real DUT.")
        return 1

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # ── Session resolution (LOG023) ───────────────────────────────────────────
    session_path = out_dir / "reboot_session.json"
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
            "test":       "reboot",
            "m":          m,
            "n":          0,
            "status":     "running",
            "started_at": function.now_iso(),
            "updated_at": function.now_iso(),
        }
        function.write_json(str(session_path), session)

    stem      = f"reboot_{session_id}"
    log_path  = out_dir / f"{stem}.log"
    json_path = out_dir / f"{stem}.result.json"

    function.setup_logging(str(log_path))
    signal.signal(signal.SIGINT, _sigint_handler)

    log.info("Reboot Test")
    log.info("  Session : %s%s", session_id, "  (RESUMING)" if resuming else "")
    log.info("  Host    : %s",   args.host or "(liveness disabled)")
    log.info("  Cycles  : m=%d, starting at n=%d", m, start_n)
    log.info("  Off wait: %ds",  args.off_time)
    log.info("  Boot TO : %ds",  args.boot_timeout)
    log.info("  SSH user: %s",   args.ssh_user or "(none)")
    log.info("  SSH cmd : %s",   args.ssh_cmd)
    log.info("  Log     : %s",   log_path)
    log.info("  JSON    : %s",   json_path)

    if args.dry_run:
        log.info("  *** DRY-RUN mode — SSH will NOT be called ***")

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

    if resuming:
        result = function.read_json(str(json_path)) or _new_result(args, session_id, m)
        result["cycles"] = result.get("cycles", [])[: session["n"]]
        log.info("Resuming session %s: %d of %d cycles already recorded",
                 session_id, len(result["cycles"]), m)
    else:
        result = _new_result(args, session_id, m)

    consecutive_fails = 0
    last_n = start_n - 1

    for n in range(start_n, m + 1):
        if _stop_requested:
            log.info("Stop requested — exiting loop after cycle %d", n - 1)
            break

        rec = run_one_cycle(n, m, args, checker)
        result["cycles"].append(rec)
        last_n = n

        if rec["verdict"] == PASS:
            consecutive_fails = 0
        else:
            consecutive_fails += 1
            log.warning("Consecutive fails: %d / %d",
                        consecutive_fails, config.MAX_CONSECUTIVE_FAILS)
            if (config.MAX_CONSECUTIVE_FAILS > 0
                    and consecutive_fails >= config.MAX_CONSECUTIVE_FAILS):
                log.error("Reached %d consecutive failures — aborting.",
                          config.MAX_CONSECUTIVE_FAILS)
                break

        result["summary"] = _build_summary(result["cycles"], m)
        result["overall_verdict"] = "RUNNING"
        function.write_result_json(str(json_path), result)

        session["n"] = n
        session["updated_at"] = function.now_iso()
        function.write_json(str(session_path), session)

    # Mark session complete if all cycles ran without interruption.
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
    log.info("Result JSON: %s", json_path)

    # Render the HTML report from the canonical result.json (FWK028).
    html_path = out_dir / f"{stem}.report.html"
    generate_report(result, str(html_path))
    log.info("HTML report: %s", html_path)

    s = result["summary"]
    log.info("=" * 50)
    log.info("RESULT:  %s", result["overall_verdict"])
    log.info("Total ran : %d / %d", s["total_ran"], s["cycles_target"])
    log.info("Pass      : %d", s["pass"])
    log.info("Fail      : %d  (NO_BOOT=%d  SSH_ERROR=%d)",
             s["fail"],
             s["fail_breakdown"][NO_BOOT],
             s["fail_breakdown"][SSH_ERROR])
    log.info("=" * 50)

    return 0 if result["overall_verdict"] == PASS else 1


if __name__ == "__main__":
    sys.exit(main())
