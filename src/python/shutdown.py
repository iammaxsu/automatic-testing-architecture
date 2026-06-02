# shutdown.py — Multi-strategy DUT shutdown coordinator
#
# Shutdown priority order:
#   1. SSH command   — "shutdown /s /t 5" via ssh; Windows exits cleanly before relay acts
#   2. ATX soft press — 0.5 s relay pulse (ACPI power button signal)
#   3. ATX force-off  — 5 s hold; applied automatically if soft press times out
#   4. Time-based     — blind wait then ATX press; last resort when no liveness checker
#
# Serial port is reserved for future expansion (placeholder below).
#
# Usage:
#   sd = ShutdownCoordinator(relay=relay, checker=checker,
#                             psu_type=args.type, ssh_user=args.ssh_user,
#                             ssh_host=args.host)
#   result = sd.request()
#   # result = {"method": "ssh"|"atx"|"force"|"time",
#   #           "success": bool, "elapsed_sec": float, "force_used": bool}

import logging
import subprocess
import time

import config

log = logging.getLogger(__name__)

METHOD_SSH   = "ssh"
METHOD_ATX   = "atx"
METHOD_FORCE = "force"
METHOD_TIME  = "time"


class ShutdownCoordinator:
    """
    Shuts down a DUT using the best available method.

    Construct once per test run and call request() for each cycle.
    The coordinator is stateless between calls.
    """

    def __init__(
        self,
        relay=None,                                    # RelayController | None
        checker=None,                                  # LivenessChecker | None
        psu_type: str = "ATX",
        ssh_user: str = "",                            # empty = skip SSH method
        ssh_host: str = "",                            # defaults to checker host if empty
        ssh_port: int = config.DUT_PORT,
        ssh_timeout_sec: int = 10,
        dead_timeout_sec: int = config.DEAD_TIMEOUT_SEC,
        time_based_delay_sec: int = config.OFF_TIME_SEC,
    ):
        self.relay                = relay
        self.checker              = checker
        self.psu_type             = psu_type
        self.ssh_user             = ssh_user
        self.ssh_host             = ssh_host or (checker.host if checker else "")
        self.ssh_port             = ssh_port
        self.ssh_timeout_sec      = ssh_timeout_sec
        self.dead_timeout_sec     = dead_timeout_sec
        self.time_based_delay_sec = time_based_delay_sec

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def request(self) -> dict:
        """
        Attempt shutdown using the highest-priority method available.

        Returns a dict:
          method       — "ssh" | "atx" | "force" | "time"
          success      — True if DUT confirmed offline; False for time-based or errors
          elapsed_sec  — seconds from first action to DUT offline (or blind wait)
          force_used   — True if force-off had to be applied after soft press timeout
        """
        # ── 1. SSH shutdown command ───────────────────────────────────
        if self.ssh_user and self.ssh_host:
            ok, elapsed = self._try_ssh()
            if ok:
                log.info("Shutdown via SSH completed in %.1f s", elapsed)
                return _rec(METHOD_SSH, True, elapsed, False)
            log.warning("SSH shutdown failed — falling back to ATX press")

        # ── 2. Relay soft press ───────────────────────────────────────
        if self.relay:
            ok, elapsed, force = self._try_relay_soft()
            method = METHOD_FORCE if force else METHOD_ATX
            return _rec(method, ok, elapsed, force)

        # ── 3. Serial port (future) ───────────────────────────────────
        # Placeholder: issue a serial shutdown command when a serial
        # connection is available (e.g. pyserial).
        # if self.serial:
        #     ok, elapsed = self._try_serial()
        #     if ok:
        #         return _rec("serial", True, elapsed, False)

        # ── 4. Time-based (no relay, no checker) ─────────────────────
        log.warning("No relay available — time-based shutdown fallback (%ds)",
                    self.time_based_delay_sec)
        time.sleep(self.time_based_delay_sec)
        return _rec(METHOD_TIME, False, float(self.time_based_delay_sec), False)

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    def _try_ssh(self):
        """
        Issue 'shutdown /s /t 5' via SSH, then wait for DUT to go offline.
        Returns (success, elapsed_sec).
        """
        cmd = [
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",            # never prompt for password
            "-o", f"ConnectTimeout={self.ssh_timeout_sec}",
            "-p", str(self.ssh_port),
            f"{self.ssh_user}@{self.ssh_host}",
            "shutdown /s /t 5",
        ]
        log.info("SSH shutdown: %s@%s", self.ssh_user, self.ssh_host)
        try:
            subprocess.run(
                cmd,
                timeout=self.ssh_timeout_sec + 5,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as exc:
            log.debug("SSH shutdown command error: %s", exc)
            return False, 0.0

        # SSH command accepted — wait for DUT to go offline
        if self.checker:
            dead, elapsed = self.checker.wait_until_dead(self.dead_timeout_sec)
            return dead, elapsed

        # No checker: assume success, wait a fixed settling time
        time.sleep(20)
        return True, 20.0

    def _try_relay_soft(self):
        """
        ATX soft press (or AT power-off) → wait for DUT offline.
        Falls through to force-off if soft press times out.
        Returns (success, elapsed_sec, force_used).
        """
        t0 = time.monotonic()

        try:
            if self.psu_type == "ATX":
                self.relay.atx_press(config.ATX_SHORT_PRESS_SEC)
            else:
                self.relay.at_power_off()
        except Exception as exc:
            log.error("Relay error during soft power-off: %s", exc)
            return False, time.monotonic() - t0, False

        if not self.checker:
            # No way to confirm — treat relay press as success
            return True, time.monotonic() - t0, False

        dead, shut_t = self.checker.wait_until_dead(self.dead_timeout_sec)
        if dead:
            return True, shut_t, False

        # Soft press timed out → force-off
        log.warning("Soft shutdown timed out (%ds) — applying force-off", self.dead_timeout_sec)
        try:
            if self.psu_type == "ATX":
                self.relay.atx_force_off(config.ATX_LONG_PRESS_SEC)
            else:
                self.relay.at_power_off()
        except Exception as exc:
            log.error("Relay error during force-off: %s", exc)

        return False, time.monotonic() - t0, True


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------

def _rec(method: str, success: bool, elapsed: float, force: bool) -> dict:
    return {
        "method":      method,
        "success":     success,
        "elapsed_sec": round(elapsed, 2),
        "force_used":  force,
    }
