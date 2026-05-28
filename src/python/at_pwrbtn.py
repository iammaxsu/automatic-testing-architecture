# GPIO Configuration 
import RPi.GPIO as GPIO         # GPIO library: RPi.GPIO or GPIO Zero
import time

GPIO.setmode(GPIO.BOARD)            # GPIO setting mode: GPIO.BOARD & GPIO.BCM
_inPin1=40           # Pin40 (GPIO21)
GPIO.setup(_inPin1, GPIO.OUT)         # Configure the pin of GPIO to IN or OUT


try:
    _state = GPIO.input(_inPin1)
    if _state == "0":
        print(f"Power is Off!")
    else: 
        print(f"Power is On!")
    
except KeyboardInterrupt:
    print(f"\n")

finally:
    GPIO.cleanup()
