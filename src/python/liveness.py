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

    def ping(self) -> bool:
        """Return True if host responds to ICMP echo."""
        try:
            result = subprocess.run(
                ["ping", "-c", str(self.ping_count), "-W", str(self.ping_timeout), self.host],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=self.ping_count * self.ping_timeout + 2,
            )
            return result.returncode == 0
        except Exception as exc:
            log.debug("ping error: %s", exc)
            return False

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
            if self.is_alive():
                self.ping_seen_during_wait = True
                elapsed = timeout_sec - (deadline - time.monotonic())
                log.info("DUT alive after %.1f s", elapsed)
                return True, elapsed
            # Distinguish "ping OK but port not ready yet" for informative logging
            if self.ping():
                self.ping_seen_during_wait = True
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
            if not self.ping():
                elapsed = timeout_sec - (deadline - time.monotonic())
                log.info("DUT offline after %.1f s", elapsed)
                return True, elapsed
            log.debug("DUT still pingable")
            time.sleep(poll_interval)

        log.warning("DUT still responds after %d s — possible hang-shutdown", timeout_sec)
        return False, timeout_sec
