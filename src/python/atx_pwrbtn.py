# GPIO Configuration 
import RPi.GPIO as GPIO         # GPIO library: RPi.GPIO or GPIO Zero
import time

GPIO.setmode(GPIO.BOARD)            # GPIO setting mode: GPIO.BOARD & GPIO.BCM
inPin1=40           # Pin40 (GPIO21)
GPIO.setup(inPin1, GPIO.OUT)         # Configure the pin of GPIO to IN or OUT


try:
    GPIO.output(inPin1, GPIO.LOW)
    time.sleep(1)
    GPIO.output(inPin1, GPIO.HIGH)
    
except KeyboardInterrupt:
    print(f"\n")

finally:
    GPIO.cleanup()
