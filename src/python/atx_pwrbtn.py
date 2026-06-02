# GPIO Configuration
import RPi.GPIO as GPIO         # GPIO library: RPi.GPIO or GPIO Zero
import time

GPIO.setmode(GPIO.BOARD)            # GPIO setting mode: GPIO.BOARD & GPIO.BCM
IN_PIN1 = 40           # Pin40 (GPIO21)
GPIO.setup(IN_PIN1, GPIO.OUT)         # Configure the pin of GPIO to IN or OUT


try:
    GPIO.output(IN_PIN1, GPIO.LOW)
    time.sleep(1)
    GPIO.output(IN_PIN1, GPIO.HIGH)

except KeyboardInterrupt:
    print(f"\n")

finally:
    GPIO.cleanup()
