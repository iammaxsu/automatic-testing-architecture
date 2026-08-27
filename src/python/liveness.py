# liveness.py — Network-based DUT health checker
#
# Two-layer check:
#   1. ICMP ping   — confirms network reachability
#   2. TCP connect — confirms a service (default: SSH port 22) is accepting
#
# A DUT is considered "alive" only when BOTH checks pass.
# This catches cases where the DUT is still booting (ping responds but
# SSH is not yet ready) and reports them separately.

import socket
import subprocess
import time
import logging
from typing import Tuple

import config

log = logging.getLogger(__name__)


class LivenessChecker:
    def __init__(
        self,
        host: str,
        port: int = 22,
        ping_count: int = 2,
        ping_timeout: int = 2,
        tcp_timeout: int = 3,
    ):
        self.host = host
        self.port = port
        self.ping_count = ping_count
        self.ping_timeout = ping_timeout
        self.tcp_timeout = tcp_timeout
        # Set by wait_until_alive(): did the DUT respond to ping during the wait?
        self.ping_seen_during_wait = False

    # ------------------------------------------------------------------
    # Low-level probes
    # ------------------------------------------------------------------

    def ping(self, count: int = None, timeout: int = None) -> bool:
        """Return True if host responds to ICMP echo.

        count/timeout override the instance defaults. The polling loops pass the
        cheaper PING_*_POLL pair, because inside them the probe's own duration is
        part of the measured time, not overhead outside it (BUG0067).
        """
        count   = self.ping_count   if count   is None else count
        timeout = self.ping_timeout if timeout is None else timeout
        try:
            result = subprocess.run(
                ["ping", "-c", str(count), "-W", str(timeout), self.host],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=count * timeout + 2,
            )
            return result.returncode == 0
        except Exception as exc:
            log.debug("ping error: %s", exc)
            return False

    def _poll_ping(self) -> bool:
        """The cheap single-echo probe used inside the polling loops."""
        return self.ping(config.PING_COUNT_POLL, config.PING_TIMEOUT_POLL_SEC)

    def tcp_check(self) -> bool:
        """Return True if TCP port accepts a connection."""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.tcp_timeout)
            result = sock.connect_ex((self.host, self.port))
            sock.close()
            return result == 0
        except Exception as exc:
            log.debug("tcp_check error: %s", exc)
            return False

    def is_alive(self) -> bool:
        """Return True only when ping AND TCP both succeed.

        Used to confirm a *full* boot (network up AND SSH accepting) before a
        test starts issuing commands. Contrast with is_up().
        """
        return self.ping() and self.tcp_check()

    def is_up(self) -> bool:
        """Return True when EITHER ping OR TCP responds.

        Used by init_dut() to decide whether the DUT needs intervention: if the
        DUT responds to anything at all it is powered and reachable, so leave it
        alone. Only when neither responds is the DUT considered down (off or
        hung) and a GPIO recovery escalation is warranted.
        """
        return self.ping() or self.tcp_check()

    def is_reachable(self) -> bool:
        """Return True if ping succeeds (regardless of TCP)."""
        return self.ping()

    # ------------------------------------------------------------------
    # Polling helpers
    # ------------------------------------------------------------------

    def wait_until_alive(
        self, timeout_sec: float, poll_interval: float = None
    ) -> Tuple[bool, float]:
        """Poll until DUT is fully alive or timeout expires.

        Returns (success, elapsed_seconds).

        Side effect: sets self.ping_seen_during_wait to True if the DUT responded
        to ping at any point during the wait. On a timeout (returns False) this
        lets the caller distinguish "the DUT was booting (ping came up) but SSH
        was not ready in time" from "the DUT never responded at all". The second
        is ambiguous on purpose: no power-on and a DUT stopped at a boot menu or
        recovery screen are indistinguishable from the network (BUG0064).
        """
        poll_interval = config.LIVENESS_POLL_SEC if poll_interval is None else poll_interval
        deadline = time.monotonic() + timeout_sec
        self.ping_seen_during_wait = False
        log.info("Waiting for DUT %s (max %ds) …", self.host, timeout_sec)

        while time.monotonic() < deadline:
            # One probe per iteration, reused for both decisions: pinging twice
            # to answer "alive?" and then "was that ping OK?" would double this
            # loop's contribution to the measured boot time.
            pinged = self._poll_ping()
            if pinged:
                self.ping_seen_during_wait = True
                if self.tcp_check():
                    elapsed = timeout_sec - (deadline - time.monotonic())
                    log.info("DUT alive after %.1f s", elapsed)
                    return True, elapsed
                log.info("ping OK — TCP port %d not ready yet", self.port)
            else:
                log.info("no ping response from %s", self.host)
            time.sleep(poll_interval)

        log.warning("DUT did not come online within %d s", timeout_sec)
        return False, timeout_sec

    def wait_until_dead(
        self, timeout_sec: float, poll_interval: float = None
    ) -> Tuple[bool, float]:
        """Poll until DUT stops responding to ping or timeout expires.

        Returns (success, elapsed_seconds).

        The elapsed time is "how long until the DUT left the network", which is
        NOT "how long until the DUT lost power" (BUG0067). The network stack
        goes down early in an OS shutdown; the machine keeps working for some
        seconds afterwards, and that tail is invisible from here — it is what
        OFF_TIME_SEC exists to absorb. The figure also carries up to one
        poll_interval of positive error, because the change is only seen at the
        next probe.
        """
        poll_interval = config.LIVENESS_POLL_SEC if poll_interval is None else poll_interval
        deadline = time.monotonic() + timeout_sec
        log.info("Waiting for DUT %s to go offline (max %ds) …", self.host, timeout_sec)

        while time.monotonic() < deadline:
            if not self._poll_ping():
                # A single-echo probe is cheap enough to keep the resolution
                # honest, but one dropped packet must not end the phase and
                # under-report the time. Confirm before believing it.
                if self._poll_ping():
                    log.debug("lone missed echo — DUT still up")
                    time.sleep(poll_interval)
                    continue
                elapsed = timeout_sec - (deadline - time.monotonic())
                log.info("DUT offline after %.1f s", elapsed)
                return True, elapsed
            log.debug("DUT still pingable")
            time.sleep(poll_interval)

        log.warning("DUT still responds after %d s — possible hang-shutdown", timeout_sec)
        return False, timeout_sec
