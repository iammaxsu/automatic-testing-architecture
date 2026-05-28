# relay.py — GPIO relay abstraction for AT and ATX power button simulation
#
# AT PSU:  relay is a maintained switch — CLOSED = power on, OPEN = power off.
# ATX PSU: relay simulates a momentary button press on the ATX power header.
#          Short press (≤1 s) = power on or soft-shutdown request.
#          Long press (≥4 s) = force power off.
#
# Wiring assumption (most RPi relay modules):
#   RELAY_ACTIVE_LOW = True  →  GPIO LOW  energises coil  → contacts CLOSE
#                               GPIO HIGH de-energises coil → contacts OPEN
#   If your module is active-HIGH, set RELAY_ACTIVE_LOW = False in config.py.

import time
import logging

log = logging.getLogger(__name__)

try:
    import RPi.GPIO as GPIO
    _GPIO_AVAILABLE = True
except ImportError:
    _GPIO_AVAILABLE = False
    log.warning("RPi.GPIO not available — relay calls will be simulated (dry-run mode)")


class RelayController:
    """Controls a single relay connected to one RPi GPIO pin."""

    def __init__(self, pin: int, active_low: bool = True, mode: str = "BOARD"):
        self.pin = pin
        self.active_low = active_low
        self._dry_run = not _GPIO_AVAILABLE

        if not self._dry_run:
            _mode = GPIO.BOARD if mode.upper() == "BOARD" else GPIO.BCM
            GPIO.setmode(_mode)
            GPIO.setwarnings(False)
            GPIO.setup(pin, GPIO.OUT)
            self._open()   # Ensure relay starts de-energised
            log.debug("RelayController: pin=%d active_low=%s mode=%s", pin, active_low, mode)
        else:
            log.debug("RelayController: dry-run mode (pin=%d)", pin)

    # ------------------------------------------------------------------
    # Internal primitives
    # ------------------------------------------------------------------

    def _close(self):
        """Energise relay coil → contacts close."""
        if self._dry_run:
            log.debug("[DRY-RUN] relay CLOSE")
            return
        GPIO.output(self.pin, GPIO.LOW if self.active_low else GPIO.HIGH)

    def _open(self):
        """De-energise relay coil → contacts open."""
        if self._dry_run:
            log.debug("[DRY-RUN] relay OPEN")
            return
        GPIO.output(self.pin, GPIO.HIGH if self.active_low else GPIO.LOW)

    # ------------------------------------------------------------------
    # ATX PSU interface
    # ------------------------------------------------------------------

    def atx_press(self, duration: float = 0.5) -> None:
        """ATX short press: simulate pressing the power button briefly.

        Typical use:
          - When DUT is OFF → turns DUT on.
          - When DUT is ON  → sends soft-shutdown request to OS.
        """
        log.info("ATX press  duration=%.1f s", duration)
        self._close()
        time.sleep(duration)
        self._open()

    def atx_force_off(self, duration: float = 5.0) -> None:
        """ATX long press: hold power button ≥4 s to force power off."""
        log.info("ATX force-off  duration=%.1f s", duration)
        self._close()
        time.sleep(duration)
        self._open()

    # ------------------------------------------------------------------
    # AT PSU interface
    # ------------------------------------------------------------------

    def at_power_on(self) -> None:
        """AT PSU: close relay to connect power (maintained state)."""
        log.info("AT power ON  (relay CLOSE)")
        self._close()

    def at_power_off(self) -> None:
        """AT PSU: open relay to cut power (maintained state)."""
        log.info("AT power OFF (relay OPEN)")
        self._open()

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    def cleanup(self) -> None:
        """De-energise relay and release GPIO resources."""
        self._open()
        if not self._dry_run:
            GPIO.cleanup(self.pin)
        log.debug("RelayController: cleanup done")
