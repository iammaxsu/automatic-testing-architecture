#!/usr/bin/env python3
# spike_probe.py - evaluation spike for the IPMI test engine decision.
#
# THROWAWAY probe (not production). It answers one question empirically:
# which IPMI connection method actually talks to THIS BMC, so we can pick
# the engine for Phase 1 instead of guessing.
#
# Background discovered while preparing this spike (verified in source):
#   - python-ipmi native 'rmcp' interface speaks IPMI *1.5* only
#     (Get Session Challenge / Activate Session / MD5 — no RMCP+/RAKP).
#   - python-ipmi 'ipmitool' backend can do IPMI *2.0* (lanplus) but only
#     if interface_type='lanplus' is passed; it defaults to 'lan' (1.5).
#   - The Kontron robotframework-ipmilibrary connection keywords use those
#     same paths, defaulting to IPMI 1.5 over LAN (see spike_ipmi.robot).
# Many modern BMCs disable IPMI 1.5, so a board reachable via `ipmitool -I
# lanplus` may still refuse every 1.5 path. This probe measures exactly that.
#
# Probes (each independent; one failing never aborts the others):
#   A  ipmitool CLI, lanplus            -> control / baseline reachability
#   B  python-ipmi, ipmitool backend, lanplus (IPMI 2.0)  -> best candidate
#   C  python-ipmi, native rmcp (IPMI 1.5)                -> 1.5-allowed?
#
# Password is read from the IPMI_PASSWORD environment variable (never a CLI
# arg, never logged).
#
# Usage:
#   export IPMI_PASSWORD='...'
#   ./spike_probe.py -H 10.0.0.124 -U admin [-t 0x20] [--timeout 20]
#
# Exit code: 0 if at least one probe succeeded, 1 otherwise.

import argparse
import os
import signal
import subprocess
import sys
import time


class Timeout(Exception):
    pass


class deadline:
    """Per-probe wall-clock guard so a non-responsive BMC can't hang the run."""

    def __init__(self, seconds):
        self.seconds = int(seconds)

    def __enter__(self):
        if self.seconds > 0 and hasattr(signal, "SIGALRM"):
            signal.signal(signal.SIGALRM, self._raise)
            signal.alarm(self.seconds)

    def __exit__(self, *exc):
        if self.seconds > 0 and hasattr(signal, "SIGALRM"):
            signal.alarm(0)

    @staticmethod
    def _raise(signum, frame):
        raise Timeout("probe exceeded time budget")


def probe_ipmitool_cli(host, user, password, timeout, iface="lanplus"):
    cmd = ["ipmitool", "-I", iface, "-H", host, "-U", user, "-E", "mc", "info"]
    env = dict(os.environ, IPMI_PASSWORD=password)
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, env=env)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip()[:300] or
                           "ipmitool returned non-zero")
    first = next((l.strip() for l in proc.stdout.splitlines()
                  if "Manufacturer" in l or "Product" in l), "")
    return "mc info ok" + (" | " + first if first else "")


def probe_python_ipmi(host, user, password, target, backend):
    import pyipmi
    import pyipmi.interfaces

    if backend == "ipmitool-lanplus":
        interface = pyipmi.interfaces.create_interface(
            "ipmitool", interface_type="lanplus")
    elif backend == "native-rmcp":
        interface = pyipmi.interfaces.create_interface("rmcp")
    else:
        raise ValueError(backend)

    conn = pyipmi.create_connection(interface)
    conn.target = pyipmi.Target(target)
    conn.session.set_session_type_rmcp(host, port=623)
    conn.session.set_auth_type_user(user, password)
    conn.session.set_priv_level("ADMINISTRATOR")
    # conn.open() runs interface.open() (creates the rmcp socket) *then*
    # session.establish(); calling session.establish() alone skips the
    # socket setup the native rmcp interface needs.
    conn.open()
    try:
        did = conn.get_device_id()
        return str(did)
    finally:
        try:
            conn.close()
        except Exception:
            pass


PROBES = [
    ("A", "ipmitool CLI (lanplus, IPMI 2.0)  [control]",
     lambda a: probe_ipmitool_cli(a.host, a.user, a.password, a.timeout)),
    ("B", "python-ipmi + ipmitool backend (lanplus, IPMI 2.0)",
     lambda a: probe_python_ipmi(a.host, a.user, a.password, a.target,
                                 "ipmitool-lanplus")),
    ("C", "python-ipmi native rmcp (IPMI 1.5)",
     lambda a: probe_python_ipmi(a.host, a.user, a.password, a.target,
                                 "native-rmcp")),
]


def recommend(results):
    ok = {k for k, v in results.items() if v[0] == "PASS"}
    print("\n" + "=" * 70)
    print("ENGINE DECISION")
    print("=" * 70)
    if "B" in ok:
        print("=> Probe B passed: python-ipmi drives THIS BMC over IPMI 2.0")
        print("   (lanplus) with STRUCTURED returns (no text parsing).")
        print("   RECOMMEND: build Phase 1 on python-ipmi via the ipmitool")
        print("   backend with interface_type='lanplus'. The Kontron RF")
        print("   keywords don't expose lanplus, so wrap python-ipmi in our")
        print("   own thin RF keyword library (BMCLibrary-style), OR subclass")
        print("   the Kontron library to force lanplus. Check spike_ipmi.robot")
        print("   results: if its tests FAILED, that confirms the lib is 1.5-only.")
    elif "C" in ok:
        print("=> Probe C passed but B did not: this BMC accepts IPMI 1.5.")
        print("   The Kontron RF library works out-of-box (it speaks 1.5).")
        print("   CAUTION: IPMI 1.5 auth is weak and often disabled in the")
        print("   field; prefer lanplus if you can enable it. Re-check why B")
        print("   failed before standardizing on 1.5.")
    elif "A" in ok:
        print("=> Only the ipmitool CLI works; both python-ipmi paths failed.")
        print("   RECOMMEND: stay with the proven approach - extend our")
        print("   existing BMCLibrary.py that wraps the ipmitool CLI. Capture")
        print("   the python-ipmi errors above for the record.")
    else:
        print("=> Nothing connected. This is a connectivity / credential")
        print("   problem, not an engine choice. Verify host, user, password")
        print("   (IPMI_PASSWORD), network path to port 623/udp, then re-run.")
    print("=" * 70)


def main():
    ap = argparse.ArgumentParser(description="IPMI engine evaluation spike")
    ap.add_argument("-H", "--host", required=True)
    ap.add_argument("-U", "--user", required=True)
    ap.add_argument("-t", "--target", default="0x20",
                    help="BMC IPMB target address (default 0x20)")
    ap.add_argument("--timeout", type=int, default=20,
                    help="per-probe time budget in seconds (default 20)")
    args = ap.parse_args()

    args.password = os.environ.get("IPMI_PASSWORD", "")
    if not args.password:
        print("[FATAL] IPMI_PASSWORD environment variable is not set",
              file=sys.stderr)
        return 2
    args.target = int(args.target, 0)

    print("IPMI engine evaluation spike")
    print("target: %s@%s  (IPMB 0x%02X)  per-probe timeout %ds\n"
          % (args.user, args.host, args.target, args.timeout))

    results = {}
    for key, label, fn in PROBES:
        print("-" * 70)
        print("Probe %s: %s" % (key, label))
        t0 = time.monotonic()
        try:
            with deadline(args.timeout):
                detail = fn(args)
            dt = time.monotonic() - t0
            results[key] = ("PASS", detail, dt)
            print("  PASS (%.1fs): %s" % (dt, detail))
        except Timeout:
            dt = time.monotonic() - t0
            results[key] = ("FAIL", "timeout after %ds" % args.timeout, dt)
            print("  FAIL (%.1fs): timeout" % dt)
        except Exception as exc:  # noqa: BLE001 - probe must never crash the run
            dt = time.monotonic() - t0
            msg = ("%s: %s" % (type(exc).__name__, exc)).strip()
            results[key] = ("FAIL", msg, dt)
            print("  FAIL (%.1fs): %s" % (dt, msg))

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    for key, label, _ in PROBES:
        verdict, detail, dt = results[key]
        print("  Probe %s  %-4s  %5.1fs  %s"
              % (key, verdict, dt, detail if verdict == "FAIL" else label))
    recommend(results)

    return 0 if any(v[0] == "PASS" for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
