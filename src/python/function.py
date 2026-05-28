import os
import time

_countfile = "counter.log"

def read_count():
    if os.path.exists(_countfile):
        with open(_countfile, "r") as f:
            _count = f.read().strip()
            return int(_count) if _count.isdigit() else 0
    return 0
    
def write_count(_count):
    with open(_countfile, "w") as f:
        f.write(str(_count) + "\n")

def update_count(mock=False):
    _count = read_count() + 1
    write_count(_count)
    return (_count)

def start_time():
    ## Record Start Time.
    return time.time()

def end_time(start_time):
    ## Calculate & return elapsed time.
    elapsed_time = time.time() - start_time
    return elapsed_time

if __name__ == "__main__":
    _count = update_count()
    print(f" {_count} of boot cycles")
    