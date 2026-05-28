#!/usr/bin/env python3
# gpioclean.py — release all GPIO resources and ensure relay is de-energised.
# Run this manually if a test is interrupted and GPIO pins are left in an
# unknown state.

import config

try:
    import RPi.GPIO as GPIO
    GPIO.setmode(GPIO.BOARD if config.GPIO_MODE.upper() == "BOARD" else GPIO.BCM)
    GPIO.setup(config.GPIO_PIN, GPIO.OUT)
    # De-energise relay (active-low: HIGH = off)
    GPIO.output(config.GPIO_PIN, GPIO.HIGH if config.RELAY_ACTIVE_LOW else GPIO.LOW)
    GPIO.cleanup()
    print(f"GPIO pin {config.GPIO_PIN} released. Relay de-energised.")
except ImportError:
    print("RPi.GPIO not available — nothing to clean up.")
except Exception as exc:
    print(f"Error during cleanup: {exc}")
