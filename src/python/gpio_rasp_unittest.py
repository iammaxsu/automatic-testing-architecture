# GPIO Configuration 
import RPi.GPIO as GPIO         # GPIO library: RPi.GPIO or GPIO Zero
import time
import unittest
import function     # function.py

GPIO.setmode(GPIO.BOARD)            # GPIO setting mode: GPIO.BOARD & GPIO.BCM
inPin1=40           # Pin40 (GPIO21)
GPIO.setup(inPin1, GPIO.OUT)         # Configure the pin of GPIO to IN or OUT


class BootTest(unittest.TestCase):

    def setUp(self):
        self._pwrtype = input("Please input your power type: ATX or AT? ").upper()
        self._bootcycle = int(input("How many cycles to run? "))
        self._pwrontime = int(input("How many SECONDS for Power ON? "))
        self._pwrofftime = int(input("How many SECONDS for Power OFF? "))

    def tearDown(self):
        print("Boot Test is done!")
        GPIO.cleanup()

    def run_atxboot(self):
        if self._pwrtype == "ATX":
            for _ in range(self._bootcycle):
                # Power on 
                GPIO.output(inPin1, GPIO.LOW)
                time.sleep(1)
                GPIO.output(inPin1, GPIO.HIGH)
                _count = function.update_count()
                print(f"{_count} Cycle of Power ON!")

                time.sleep(self._pwrontime)

                # Power off
                GPIO.output(inPin1, GPIO.LOW)
                time.sleep(1)
                GPIO.output(inPin1, GPIO.HIGH)
                print(f"{_count} Cycle of Power OFF!")

                time.sleep(self._pwrofftime)

            self.assertTrue(True)

    def run_atboot(self):
        if self._pwrtype == "AT":
            for _ in range(self._bootcycle):
                # Power on 
                GPIO.output(inPin1, GPIO.LOW)
                time.sleep(1)
                GPIO.output(inPin1, GPIO.HIGH)
                _count = function.update_count()
                print(f"{_count} Cycle of Power ON!")

                time.sleep(self._pwrontime)

                # Power off
                GPIO.output(inPin1, GPIO.LOW)
                time.sleep(1)
                GPIO.output(inPin1, GPIO.HIGH)
                print(f"{_count} Cycle of Power OFF!")

                time.sleep(self._pwrofftime)

            self.assertTrue(True)
    def test_pwrboot(self):
        if self._pwrtype == "ATX":
            self.run_atxboot()
        elif self._pwrtype == "AT":
            self.run_atboot()
        else:
            self.fail("Invalid power type!")

if __name__ == "__main__":
    unittest.main()
    