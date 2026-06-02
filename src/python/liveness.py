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
        """Return True only when ping AND TCP both succeed."""
        return self.ping() and self.tcp_check()

    def is_reachable(self) -> bool:
        """Return True if ping succeeds (regardless of TCP)."""
        return self.ping()

    # ------------------------------------------------------------------
    # Polling helpers
    # ------------------------------------------------------------------

    def wait_until_alive(
        self, timeout_sec: float, poll_interval: float = 5.0
    ) -> Tuple[bool, float]:
        """Poll until DUT is fully alive or timeout expires.

        Returns (success, elapsed_seconds).
        """
        deadline = time.monotonic() + timeout_sec
        log.info("Waiting for DUT %s (max %ds) …", self.host, timeout_sec)

        while time.monotonic() < deadline:
            if self.is_alive():
                elapsed = timeout_sec - (deadline - time.monotonic())
                log.info("DUT alive after %.1f s", elapsed)
                return True, elapsed
            # Distinguish "ping OK but port not ready yet" for informative logging
            if self.ping():
                log.info("ping OK — TCP port %d not ready yet", self.port)
            else:
                log.info("no ping response from %s", self.host)
            time.sleep(poll_interval)

        log.warning("DUT did not come online within %d s", timeout_sec)
        return False, timeout_sec

    def wait_until_dead(
        self, timeout_sec: float, poll_interval: float = 5.0
    ) -> Tuple[bool, float]:
        """Poll until DUT stops responding to ping or timeout expires.

        Returns (success, elapsed_seconds).
        """
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
