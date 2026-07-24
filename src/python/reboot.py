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
#   --off     auto|SECONDS    inter-cycle delay, after each cycle's verdict is recorded:
#                             "auto" (default) — boot detection is already event-driven
#                             (ends the moment the DUT responds), so this just adds a
#                             short fixed settle (config.REBOOT_AUTO_SETTLE_SEC) for
#                             sshd/sudo to stabilise, then reboots immediately. An
#                             integer N overrides with a fixed N-second delay instead
#                             (0 = no delay at all).
#   --out     DIR             base output directory; sessions live under
#                             DIR/<dut-id>/reboot_<session_id>/ (LOG025)
#   --dut-id  ID              stable DUT identity for the session directory;
#                             default: derived from --host
#   --no-check                skip network liveness checks (useful for dry-run)
#   --dry-run                 run logic without issuing SSH reboot
#   --boot-timeout SECONDS    max wait for DUT to come back online (default: 120;
#                             overridden by auto-calibration when --calibrate > 0)
#   --boot-ceiling SECONDS    absolute max boot wait for init power-on + calibration,
#                             and cap on the calibrated timeout (default: 360)
#   --calibrate N             calibration cycles to auto-measure boot time before the
#                             counted test (0 = disabled; default from config)
#   --ssh-user USERNAME       SSH login for reboot command (required)
#   --ssh-cmd COMMAND         reboot command to run over SSH (default: "sudo reboot")
#   --new-session             force a new session instead of resuming an incomplete one (LOG023)
#   --debug                   stop immediately on the first non-PASS cycle, leaving DUT
#                             state as-is for inspection (overrides --early-fail-threshold /
#                             --max-consecutive-fails)
#   --bmc-host IP             BMC management IP, for Redfish firmware version fallback (PWR015)
#
# Init phase options (FWK031/PWR013) — normalise DUT state before the first cycle:
#   --pin     N               GPIO BOARD pin for power recovery (default: config.GPIO_PIN)
#   --type    ATX|AT          PSU type for power recovery (default: from config.py)
#   --init-wait SECONDS       GPIO-unavailable fallback only: wait for a powered-but-
#                             booting DUT; 0 = fail immediately
#
# Init behaviour (function.init_dut escalation chain):
#   DUT responds (ping OR SSH)       → begin first cycle immediately
#   DUT offline                      → GPIO power-on press, wait up to --boot-ceiling
#   still offline                    → GPIO force-off + power-on (DUT was hung)
#   still offline                    → abort (DUT may be dead)
#   no GPIO pin + --init-wait N      → wait up to N s for a still-booting DUT
# The ceiling (not the short --boot-timeout) is used here so a slow-but-healthy
# DUT is not force-cycled and misjudged as dead (BUG0036).
#
# Verdicts per cycle:
#   PASS      — DUT came back online within BOOT_TIMEOUT after reboot command
#   NO_BOOT   — DUT did not come back online within BOOT_TIMEOUT
#   SSH_ERROR — reboot command could not be sent (SSH unreachable before reboot)

import argparse
import copy
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
from relay import RelayController
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

def _parse_off_time(value: str):
    """--off accepts 'auto' or a non-negative integer second count."""
    if value.lower() == "auto":
        return "auto"
    try:
        n = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"--off must be 'auto' or an integer, got: {value!r}")
    if n < 0:
        raise argparse.ArgumentTypeError("--off must be 'auto' or >= 0")
    return n


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Software reboot endurance test (SSH-controlled)")
    p.add_argument("--host",          default=config.DUT_HOST,
                   help="DUT IP or hostname (required for liveness checks)")
    p.add_argument("--dut-id",        default=None, dest="dut_id",
                   help="Stable DUT identity for the session directory (LOG025); "
                        "default: derived from --host. Set this if the DUT's IP "
                        "can change (DHCP) but you want one continuous history.")
    p.add_argument("--port",          default=config.DUT_PORT, type=int,
                   help="TCP port to probe (default: %(default)s)")
    p.add_argument("--cycles",        default=config.CYCLES, type=int,
                   help="Number of reboot cycles (default: %(default)s)")
    p.add_argument("--off",           default="auto", type=_parse_off_time,
                   dest="off_time",
                   help="Inter-cycle delay after each cycle's verdict is recorded. "
                        "'auto' (default) waits a short fixed settle "
                        "(config.REBOOT_AUTO_SETTLE_SEC=%ds) then reboots immediately — "
                        "boot detection is already event-driven, so no longer fixed wait "
                        "is needed to confirm the DUT is up. An integer N uses a fixed "
                        "N-second delay instead (0 = no delay at all)." % config.REBOOT_AUTO_SETTLE_SEC)
    p.add_argument("--out",           default=config.LOG_DIR,
                   help="Output directory for logs (default: %(default)s)")
    p.add_argument("--no-check",      action="store_true",
                   help="Disable network liveness checks")
    p.add_argument("--dry-run",       action="store_true",
                   help="Simulate reboot without issuing SSH command")
    p.add_argument("--boot-timeout",  default=config.BOOT_TIMEOUT_SEC, type=int,
                   dest="boot_timeout",
                   help="Max seconds waiting for DUT to come back online (default: %(default)s). "
                        "Overridden by auto-calibration when --calibrate > 0.")
    p.add_argument("--boot-ceiling",  default=config.BOOT_CEILING_SEC, type=int,
                   dest="boot_ceiling",
                   help="Absolute maximum boot wait, used for the init power-on and the "
                        "calibration phase (before the DUT's typical boot time is known), "
                        "and as the cap on the auto-calibrated timeout (default: %(default)s)")
    p.add_argument("--calibrate",     default=config.CALIBRATE_CYCLES, type=int,
                   dest="calibrate_cycles",
                   help="Calibration cycles to measure boot time before the counted test "
                        "(0 = disabled, use --boot-timeout directly). boot_timeout is then "
                        "set to max(observed) x %.1f, capped at --boot-ceiling (default: %%(default)s)"
                        % config.CALIBRATE_SAFETY_FACTOR)
    p.add_argument("--ssh-user",      default=config.SHUTDOWN_SSH_USER,
                   dest="ssh_user",
                   help="SSH username for reboot command (required at runtime)")
    p.add_argument("--dut-os",        default="auto",
                   choices=["auto", "windows", "linux"], dest="dut_os",
                   help="DUT operating system: auto (probe via SSH), windows, or linux. "
                        "Selects the default SSH reboot command. (default: %(default)s)")
    p.add_argument("--ssh-cmd",       default=None,
                   dest="ssh_cmd",
                   help="Reboot command to run over SSH "
                        "(default: OS-appropriate command selected by --dut-os)")
    p.add_argument("--early-fail-threshold", default=config.EARLY_FAIL_THRESHOLD, type=int,
                   dest="early_fail_threshold",
                   help="Abort if first N cycles all fail before any PASS; 0 = never "
                        "(default: %(default)s)")
    p.add_argument("--max-consecutive-fails", default=config.MAX_CONSECUTIVE_FAILS, type=int,
                   dest="max_consecutive_fails",
                   help="Abort after N consecutive mid-run failures; 0 = never abort "
                        "(default: %(default)s)")
    # ── Init phase (FWK031/PWR013): normalise DUT state before the first cycle ─
    p.add_argument("--pin",       default=config.GPIO_PIN, type=int,
                   help="GPIO BOARD pin for init-phase power recovery (default: %(default)s). "
                        "If the DUT is offline at start, init_dut() uses this pin to power "
                        "it on (and, if needed, force a power cycle). Same pin as power_cycle.")
    p.add_argument("--type",      default=config.POWER_TYPE, choices=["ATX", "AT"],
                   help="PSU type for init-phase power recovery (ATX = momentary press, "
                        "AT = maintained relay). Default: %(default)s")
    p.add_argument("--init-wait", default=config.INIT_WAIT_SEC, type=int,
                   dest="init_wait",
                   help="Fallback only when GPIO is unavailable: seconds to wait for a "
                        "powered-but-still-booting DUT. 0 = fail immediately. "
                        "(default: %(default)s)")
    p.add_argument("--new-session",   action="store_true", dest="new_session",
                   help="Force a new session even if an incomplete one exists (LOG023)")
    p.add_argument("--debug", action="store_true", dest="debug",
                   help="Stop immediately on the FIRST non-PASS cycle, leaving the "
                        "DUT state as-is for inspection. Overrides "
                        "--early-fail-threshold / --max-consecutive-fails.")
    p.add_argument("--bmc-host", default=config.BMC_HOST, dest="bmc_host",
                   help="BMC's own management IP/hostname, for Redfish firmware-version "
                        "lookup (PWR015) when in-band ipmitool is unavailable. "
                        "Empty: BMC version is only attempted via ipmitool; a product "
                        "with no BMC reports 'N/A' (default: %(default)r)")
    p.add_argument("--bmc-user", default=config.BMC_USER, dest="bmc_user",
                   help="Redfish basic-auth user for --bmc-host")
    p.add_argument("--bmc-pass", default=config.BMC_PASS, dest="bmc_pass",
                   help="Redfish basic-auth password for --bmc-host")
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
        *function.ssh_base_opts(ssh_timeout),
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


def _collect_firmware(rec: dict, args: argparse.Namespace) -> None:
    """Probe BIOS/BMC firmware version once the DUT is confirmed alive (PWR015).

    Run every cycle so a firmware update applied mid-run shows up in
    result.json instead of being silently missed.
    """
    fw = function.detect_firmware(
        args.host, args.port, args.ssh_user, args.dut_os,
        bmc_host=args.bmc_host, bmc_user=args.bmc_user, bmc_pass=args.bmc_pass,
        dry_run=args.dry_run,
    )
    rec["bios_version"] = fw["bios_version"]
    rec["bmc_version"]  = fw["bmc_version"]
    rec["bmc_method"]   = fw["bmc_method"]


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
        "bios_version":    None,
        "bmc_version":     None,
        "bmc_method":      None,
        "verdict":         SSH_ERROR,
        "notes":           "",
    }

    log.info("─── Cycle %d / %d ───────────────────────────────", n, total)

    # ── 1. Issue SSH reboot ────────────────────────────────────────────────
    # Pre-check: SSH returns exit 255 for both "reboot initiated" and "connection
    # refused (DUT powered off)".  Verify DUT is pingable before sending the
    # command so we don't misread a dead DUT as a successful reboot.
    if checker and not args.dry_run and not checker.ping():
        rec["notes"] = "DUT not reachable before reboot command (ping failed)"
        rec["verdict"] = SSH_ERROR
        log.warning("Cycle %d: SSH_ERROR — DUT not pingable before reboot", n)
        return rec

    rec["t_reboot_cmd"] = function.now_iso()
    t_reboot_cmd_mono = time.monotonic()
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

    # ── 3. Wait for DUT to come back online ───────────────────────────────
    # Poll for "alive" immediately — no fixed pre-poll sleep here (BUG0027).
    # boot_time_sec is the full reboot round-trip per PWR011 §3 (reboot command
    # issued -> DUT back online), measured from t_reboot_cmd_mono rather than
    # trusting the poll's own elapsed time, so it stays correct regardless of
    # internal sleep/poll structure.
    if checker and not args.dry_run:
        alive, _ = checker.wait_until_alive(args.boot_timeout)
        rec["t_online"]      = function.now_iso()
        rec["boot_time_sec"] = round(time.monotonic() - t_reboot_cmd_mono, 2)

        if not alive:
            rec["verdict"] = NO_BOOT
            # Distinguish a slow-but-booting DUT (responded to ping, SSH not ready
            # in time) from one that never came back (never pinged) — see
            # power_cycle.py / liveness.wait_until_alive.
            if getattr(checker, "ping_seen_during_wait", False):
                rec["no_boot_kind"] = "slow_boot"
                rec["notes"] = (
                    f"boot exceeded timeout: DUT responded to ping but SSH was not "
                    f"ready within {args.boot_timeout}s (slow boot — consider a higher "
                    f"--boot-timeout / more --calibrate cycles)"
                )
            else:
                rec["no_boot_kind"] = "no_power_on"
                rec["notes"] = (
                    f"DUT never responded to ping within {args.boot_timeout}s after "
                    f"the reboot command (did it actually reboot? — not a boot-time "
                    f"timeout)"
                )
            log.warning("Cycle %d: NO_BOOT (%s, timeout %ds)",
                        n, rec["no_boot_kind"], args.boot_timeout)
            return rec

        log.info("Cycle %d: DUT back online in %.1f s", n, rec["boot_time_sec"])
        if args.ssh_user or args.bmc_host:
            _collect_firmware(rec, args)
        _t = function.notify_dut(
            args.ssh_user, args.host, args.port,
            f"Reboot test in progress - cycle {n}/{total}. Do not use.",
            dry_run=args.dry_run,
            dut_os=args.dut_os,
        )
        # Join the notification thread before starting the next reboot: without
        # this, the next shutdown /r /t 0 races ahead and the DUT is already
        # rebooting before msg.exe delivers the popup.
        if _t is not None:
            _t.join(timeout=30)
    else:
        rec["t_online"] = function.now_iso()
        log.info("Cycle %d: liveness check disabled", n)
        if args.ssh_user or args.bmc_host:
            _collect_firmware(rec, args)

    rec["verdict"] = PASS

    # ── 4. Inter-cycle delay (after the verdict is recorded, before the next
    # cycle's reboot command — not a pre-measurement delay that would hide the
    # boot-time measurement; see BUG0027) ─────────────────────────────────────
    # Boot detection (wait_until_alive above) is already event-driven — it ends
    # the moment the DUT responds, not after a fixed wait. "auto" (default) adds
    # only a short settle on top of that for sshd/sudo to stabilise; an explicit
    # integer N (mirroring power_cycle.py's --off) overrides with a fixed delay.
    delay = config.REBOOT_AUTO_SETTLE_SEC if args.off_time == "auto" else args.off_time
    if delay > 0 and not args.dry_run:
        log.info("Cycle %d: waiting %ds before next cycle …", n, delay)
        off_deadline = time.monotonic() + delay
        while time.monotonic() < off_deadline and not _stop_requested:
            time.sleep(1)

    return rec


# ── adaptive boot timeout / near-miss (mirrors power_cycle.py) ───────────────────

def _adapt_boot_timeout(args, rec: dict, result: dict = None) -> None:
    """Flag a near-miss boot and adaptively raise boot_timeout (NEAR_MISS_FRAC).

    A few calibrate cycles can under-estimate the timeout for a DUT with a
    bimodal / occasionally-long boot. When a PASSING cycle boots within
    NEAR_MISS_FRAC of the current timeout, raise the timeout to
    (boot × safety factor) capped at the ceiling, so a later slightly-slower boot
    is not failed. Disabled when NEAR_MISS_FRAC == 0.
    """
    frac = getattr(config, "NEAR_MISS_FRAC", 0)
    if not frac or rec.get("verdict") != PASS:
        return
    bt = rec.get("boot_time_sec")
    if bt is None or bt < frac * args.boot_timeout:
        return
    rec["near_miss"] = True
    ceiling = getattr(args, "boot_ceiling", config.BOOT_CEILING_SEC)
    new_to = min(round(bt * config.CALIBRATE_SAFETY_FACTOR), ceiling)
    if new_to > args.boot_timeout:
        log.warning(
            "Cycle %d: boot %.1fs is within %.0f%% of boot_timeout %ds — raising "
            "boot_timeout to %ds (adaptive; ceiling %ds)",
            rec.get("n"), bt, frac * 100, args.boot_timeout, new_to, ceiling,
        )
        args.boot_timeout = new_to
        if result is not None:
            result.setdefault("config", {})["boot_timeout_sec"] = new_to
    else:
        log.warning(
            "Cycle %d: boot %.1fs is within %.0f%% of boot_timeout %ds (already at "
            "ceiling %ds — cannot raise further)",
            rec.get("n"), bt, frac * 100, args.boot_timeout, ceiling,
        )


# ── calibration phase (BUG0036) ─────────────────────────────────────────────────

def _run_calibrate_phase(args, checker, result: dict) -> None:
    """Measure the DUT's reboot round-trip boot time, then set args.boot_timeout.

    Mirrors power_cycle.py's calibrate phase. Runs args.calibrate_cycles reboot
    cycles with the boot wait raised to boot_ceiling, records each measured boot
    time, then sets boot_timeout = max(observed) x CALIBRATE_SAFETY_FACTOR,
    capped at boot_ceiling. Calibrate cycles are NOT counted in the main summary;
    they are stored in result["calibrate"] for the report so each DUT's measured
    boot time is visible and comparable.

    Requires the DUT to already be online (call after init_dut) and SSH usable.
    """
    n_cal = args.calibrate_cycles
    log.info("=== Calibrate: %d cycle(s) — measuring boot time (ceiling %ds) ===",
             n_cal, args.boot_ceiling)

    # Temporary args: raise the boot wait to the ceiling for measurement.
    cal_args = copy.copy(args)
    cal_args.boot_timeout = args.boot_ceiling

    boot_times = []
    for c in range(1, n_cal + 1):
        if _stop_requested:
            break
        log.info("[CAL %d/%d] ──────────────────────────────────────", c, n_cal)
        rec = run_one_cycle(c, n_cal, cal_args, checker)
        boot_t = rec.get("boot_time_sec")
        log.info("[CAL %d/%d] verdict: %s  boot: %s s",
                 c, n_cal, rec["verdict"],
                 f"{boot_t:.1f}" if boot_t is not None and rec["verdict"] == PASS else "—")
        result["calibrate"]["cycles"].append({
            "n":             c,
            "verdict":       rec["verdict"],
            "boot_time_sec": boot_t,
        })
        if rec["verdict"] == PASS and boot_t is not None:
            boot_times.append(boot_t)

    if boot_times:
        computed   = round(max(boot_times) * config.CALIBRATE_SAFETY_FACTOR)
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
            "off_time_mode":    "auto" if args.off_time == "auto" else "fixed",
            "off_time_sec":     (config.REBOOT_AUTO_SETTLE_SEC if args.off_time == "auto"
                                  else args.off_time),
            "boot_timeout_sec": args.boot_timeout,
            "boot_ceiling_sec": args.boot_ceiling,
            "dead_timeout_sec": config.DEAD_TIMEOUT_SEC,
            "calibrate_cycles": args.calibrate_cycles,
            "ssh_user":         args.ssh_user or None,
            "ssh_cmd":          args.ssh_cmd,
            "dut_os":           args.dut_os,
            "debug_mode":       bool(args.debug),
            "bmc_host":         args.bmc_host or None,
        },
        "calibrate": {
            "cycles":           [],     # each calibrate cycle's measured boot_time_sec
            "boot_timeout_sec": None,   # computed from calibrate; None if skipped/failed
            "safety_factor":    config.CALIBRATE_SAFETY_FACTOR,
        },
        "cycles":          [],
        "summary":         {},
        "overall_verdict": "RUNNING",
    }


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> int:
    args = parse_args()

    # Resolve DUT OS and the reboot command.
    #
    # When --dut-os is "auto" and the DUT is reachable, DEFER the SSH probe until
    # after init_dut() has brought the DUT online (BUG0034). A probe issued while
    # the DUT is still powered off returns "unknown" and silently falls back to
    # config.DUT_OS — which sent a Linux "sudo reboot" to a Windows DUT that
    # init_dut() then powered on. Cases that cannot probe at all (dry-run,
    # --no-check, no ssh-user/host) or that already have an explicit command are
    # resolved here from config.DUT_OS.
    probe_os_after_init = False
    if args.dut_os == "auto":
        if args.dry_run or args.no_check or not args.ssh_user or not args.host:
            args.dut_os = config.DUT_OS          # can't probe — config default
        elif args.ssh_cmd is None:
            probe_os_after_init = True           # resolve after init_dut() (BUG0034)
        else:
            args.dut_os = config.DUT_OS          # explicit --ssh-cmd; OS label only

    if args.ssh_cmd is None and not probe_os_after_init:
        args.ssh_cmd = config._OS_REBOOT_CMD.get(args.dut_os, config.REBOOT_SSH_CMD)

    if not args.ssh_user and not args.dry_run and not args.no_check:
        print("ERROR: --ssh-user is required for reboot.py (no relay fallback).")
        print("       Use --dry-run to test without a real DUT.")
        return 1

    # ── Session resolution (LOG023/LOG025: DUT-first session directory) ──────────
    dut_id = function.dut_slug(args.dut_id or args.host)
    target = {
        "host":     args.host or None,
        "port":     args.port,
        "ssh_user": args.ssh_user or None,
    }
    try:
        session_dir, session_id, m, start_n, session, resuming = function.resolve_session(
            args.out, "reboot", dut_id, target, args.cycles, args.new_session)
    except function.SessionTargetMismatch as exc:
        log.error(
            "Refusing to resume session %s: target mismatch "
            "(session target=%s, current target=%s). "
            "Re-run with --host/--port/--ssh-user matching the original session, "
            "or pass --new-session to start a fresh one.",
            exc.session_id, exc.expected, exc.got,
        )
        return 1
    session_path = session_dir / "meta.json"

    stem      = f"reboot_{session_id}"
    log_path  = session_dir / f"{stem}.log"
    json_path = session_dir / f"{stem}.result.json"

    function.setup_logging(str(log_path))
    signal.signal(signal.SIGINT, _sigint_handler)

    log.info("Reboot Test")
    log.info("  Session : %s%s", session_id, "  (RESUMING)" if resuming else "")
    log.info("  Host    : %s",   args.host or "(liveness disabled)")
    log.info("  Cycles  : m=%d, starting at n=%d", m, start_n)
    log.info("  Inter-cycle delay: %s", (
        f"auto (~{config.REBOOT_AUTO_SETTLE_SEC}s settle, reboot immediately after)"
        if args.off_time == "auto" else f"{args.off_time}s fixed"))
    log.info("  Boot TO : %ds (ceiling %ds)",  args.boot_timeout, args.boot_ceiling)
    log.info("  Calibrate: %d cycle(s)%s",
             args.calibrate_cycles,
             "" if args.calibrate_cycles > 0
             else " (disabled — using --boot-timeout directly)")
    log.info("  SSH user: %s",   args.ssh_user or "(none)")
    log.info("  SSH cmd : %s",   args.ssh_cmd if args.ssh_cmd
                                  else "(auto — resolved after DUT is online)")
    log.info("  Init    : pin=%s  type=%s  init-wait=%ds (GPIO fallback)",
             args.pin if args.pin else "None", args.type, args.init_wait)
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

    # ── Init: bring DUT to a testable state (FWK031) ─────────────────────────────
    # Always runs — even on resume — because the previous test phase may have
    # left the DUT powered off (e.g. power_cycle ends with DUT off).
    # init_dut() is cheap when DUT is already up ("already-up" returns immediately).
    relay = None
    if args.pin:
        relay = RelayController(
            pin=args.pin,
            active_low=config.RELAY_ACTIVE_LOW,
            mode=config.GPIO_MODE,
            dry_run=args.dry_run,
        )
    try:
        ok, method = function.init_dut(
            checker,
            relay,
            args.type,
            # Use the ceiling (not the short per-cycle boot_timeout) so a slow but
            # healthy DUT is not force-cycled and misjudged as dead (BUG0036).
            boot_timeout=args.boot_ceiling,
            # Forced-recovery "stay off" duration (FWK031 Step 3) — a physical
            # power-cycle concern, unrelated to --off's inter-cycle pacing.
            off_time=config.OFF_TIME_SEC,
            short_press_sec=config.ATX_SHORT_PRESS_SEC,
            force_off_sec=config.ATX_LONG_PRESS_SEC,
            init_wait=args.init_wait,
            dry_run=args.dry_run,
        )
    finally:
        if relay is not None:
            relay.cleanup()
    if not ok:
        log.error("Init failed (method=%s) — cannot start reboot test.", method)
        return 1
    log.info("Init OK (method=%s) — starting test.", method)

    # ── Resolve DUT OS now that the DUT is confirmed online (BUG0034) ────────────
    # Probing here, after init_dut(), guarantees the SSH probe runs against a live
    # DUT instead of an offline one, so a Windows DUT gets "shutdown /r /t 0" and a
    # Linux DUT gets "sudo reboot" — not whatever config.DUT_OS happened to default
    # to while the machine was still powered off.
    if probe_os_after_init:
        detected     = function.detect_dut_os(args.host, args.port, args.ssh_user)
        args.dut_os  = detected if detected != "unknown" else config.DUT_OS
        args.ssh_cmd = config._OS_REBOOT_CMD.get(args.dut_os, config.REBOOT_SSH_CMD)
        log.info("  DUT OS  : %s — SSH cmd: %s", args.dut_os, args.ssh_cmd)

    if resuming:
        result = function.read_json(str(json_path)) or _new_result(args, session_id, m)
        result["cycles"] = result.get("cycles", [])[: session["n"]]
        log.info("Resuming session %s: %d of %d cycles already recorded",
                 session_id, len(result["cycles"]), m)
    else:
        result = _new_result(args, session_id, m)

    # ── Calibrate phase (new session only) ───────────────────────────────────────
    # Measure the DUT's reboot round-trip boot time and set boot_timeout for the
    # counted test automatically, so a slow-booting DUT need not pass --boot-timeout
    # by hand (BUG0036). Requires SSH (reboot is issued over SSH) and liveness.
    if (args.calibrate_cycles > 0 and not resuming and not args.dry_run
            and checker and args.ssh_user and not _stop_requested):
        _run_calibrate_phase(args, checker, result)
        try:
            function.write_result_json(str(json_path), result)  # persist calibrate data
        except OSError as exc:
            log.warning("Could not persist calibrate data (%s) — continuing", exc)

    consecutive_fails = 0
    has_had_success   = any(c.get("verdict") == PASS
                            for c in result.get("cycles", []))
    last_n      = start_n - 1
    debug_abort = False

    for n in range(start_n, m + 1):
        if _stop_requested:
            log.info("Stop requested — exiting loop after cycle %d", n - 1)
            break

        rec = run_one_cycle(n, m, args, checker)
        result["cycles"].append(rec)
        last_n = n

        _adapt_boot_timeout(args, rec, result)

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
                # Early phase: no PASS yet — likely a config/connectivity problem.
                if (args.early_fail_threshold > 0
                        and consecutive_fails >= args.early_fail_threshold):
                    log.error(
                        "First %d cycles all failed before any PASS — aborting. "
                        "Check host, SSH credentials, and DUT state.",
                        args.early_fail_threshold)
                    break
            else:
                # Mid-run phase: hardware under test — only abort if explicitly configured.
                if (args.max_consecutive_fails > 0
                        and consecutive_fails >= args.max_consecutive_fails):
                    log.warning("Consecutive fails: %d / %d",
                                consecutive_fails, args.max_consecutive_fails)
                    log.error("Reached %d consecutive mid-run failures — aborting.",
                              args.max_consecutive_fails)
                    break

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

        session["n"] = n
        session["updated_at"] = function.now_iso()
        try:
            function.write_json(str(session_path), session)
        except OSError as exc:
            log.warning("Cycle %d: session.json write failed (%s) — will retry "
                        "on next cycle", n, exc)

    # Mark session complete if all cycles ran without interruption.
    if last_n >= m and not _stop_requested:
        session["status"] = "complete"
    session["n"] = last_n
    session["updated_at"] = function.now_iso()
    function.write_json(str(session_path), session)

    # Restore DUT test-environment settings (reverses setup_dut.sh / setup_dut.ps1
    # changes).
    if session.get("status") == "complete" and args.ssh_user:
        function.restore_dut_env(args.host, args.port, args.ssh_user, args.dut_os)

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

    # Render the HTML report from the canonical result.json (FWK028).
    html_path = session_dir / f"{stem}.report.html"
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
