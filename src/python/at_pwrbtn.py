# GPIO Configuration
import RPi.GPIO as GPIO         # GPIO library: RPi.GPIO or GPIO Zero
import time

GPIO.setmode(GPIO.BOARD)            # GPIO setting mode: GPIO.BOARD & GPIO.BCM
IN_PIN1 = 40           # Pin40 (GPIO21)
GPIO.setup(IN_PIN1, GPIO.OUT)         # Configure the pin of GPIO to IN or OUT


try:
    state = GPIO.input(IN_PIN1)
    if state == "0":
        print(f"Power is Off!")
    else:
        print(f"Power is On!")

except KeyboardInterrupt:
    print(f"\n")

finally:
    GPIO.cleanup()
