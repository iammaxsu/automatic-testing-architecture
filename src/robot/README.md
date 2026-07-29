# BMC / IPMI test suites — how to run

Out-of-band BMC testing over IPMI 2.0, run from a **control node** (your
workstation / vserver) against a DUT's BMC over the network.

- The control node is the IPMI **client** — it does **not** need a BMC of its own.
- The DUT only needs standby power (so its BMC is alive); the DUT's OS does
  **not** need to be running.
- Engine: the `ipmitool` CLI, wrapped by [`lib/BMCLibrary.py`](lib/BMCLibrary.py).
  Why not python-ipmi / an RF IPMI library? See
  [`docs/architecture.md`](../../docs/architecture.md) (ADR-0001).

---

## TL;DR (forgot the syntax? start here)

```bash
cd ~/automatic-testing-architecture
source .venv/bin/activate                 # see "One-time setup" if this fails
export IPMI_PASSWORD='<bmc-password>'
robot -v BMC_HOST:10.0.0.124 -d logs/ipmi src/robot/ipmi/
```

Then open `logs/ipmi/report.html`.

---

## 1. One-time setup

Requirements: `ipmitool` and Python 3 with `venv`.

```bash
sudo apt install -y ipmitool python3-venv     # if not already installed

cd ~/automatic-testing-architecture
python3 -m venv .venv
source .venv/bin/activate
pip install robotframework
robot --version                                # expect Robot Framework 7.x
```

That is all the suites need — `BMCLibrary.py` uses only the Python standard
library plus the `ipmitool` binary.

## 2. Each session

```bash
cd ~/automatic-testing-architecture
source .venv/bin/activate                      # activate the venv
export IPMI_PASSWORD='<bmc-password>'          # never commit or hard-code this
```

`IPMI_PASSWORD` is read from the environment and passed to ipmitool via `-E`;
it never appears on a command line or in a log.

## 3. Run the functional suite (`src/robot/ipmi/`)

All read-only — safe to run against a DUT that is in use. No power control.

```bash
# whole suite (all 8 areas, 16 tests)
robot -v BMC_HOST:10.0.0.124 -d logs/ipmi src/robot/ipmi/

# one area, by file
robot -v BMC_HOST:10.0.0.124 -d logs/ipmi src/robot/ipmi/lan.robot

# one area, by tag (across the suite)
robot -v BMC_HOST:10.0.0.124 --include fru -d logs/ipmi src/robot/ipmi/
```

Areas / tags: `device-id`, `sensor`, `sel`, `chassis`, `fru`, `sdr`, `lan`, `user`.

### Common overrides (`-v NAME:value`)

Defaults live in [`ipmi/bmc.resource`](ipmi/bmc.resource); override per run with `-v`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `BMC_HOST` | *(required)* | BMC IP / hostname |
| `BMC_USER` | `admin` | IPMI user |
| `LAN_CHANNEL` | `1` | BMC LAN channel (some boards use 8) |
| `SENSOR_TEMP` | `CPU_Temp` | temperature sensor name to check |
| `SENSOR_VOLT` | `5V_DUAL` | voltage rail name to check |
| `EXPECTED_USER` | `admin` | account that must exist in `user list` |

## 4. Run the sensor soak (long-duration)

Two equivalent options — pick one:

```bash
# Robot Framework (e.g. weekend soak: 3600 cycles x 60s ~ 60h)
robot -v BMC_HOST:10.0.0.124 -v CYCLES:3600 -v INTERVAL:60 \
      -d logs/soak src/robot/bmc_sensor.robot

# standalone bash (no Robot Framework needed)
./src/bash-shell/bmc_sensor_test.sh -H 10.0.0.124 -U admin -i 60 -d 60 -o logs/soak
```

## 5. Where the results go

Robot writes to the `-d` directory:

- `report.html` — pass/fail overview (**open this first**)
- `log.html` — step-by-step detail, keyword arguments, messages
- `output.xml` — machine-readable (canonical; the HTML is rendered from it)

---

## Troubleshooting

**`ModuleNotFoundError: No module named 'robot'`**
The venv is not active, or robotframework is not installed in it.
`source .venv/bin/activate`, then `pip install robotframework`; confirm with
`robot --version`.

**Every test times out**
Connectivity or credentials, not the tests. Check: the IP is right (watch for
`.124` vs `.142` typos), `IPMI_PASSWORD` is exported, and the control node can
reach `<host>` UDP port 623. Sanity check outside Robot:
```bash
ipmitool -I lanplus -H 10.0.0.124 -U admin -E mc info
```

**LAN tests fail**
Your BMC's LAN may be on a different channel. Find it and override:
```bash
ipmitool -I lanplus -H 10.0.0.124 -U admin -E lan print 8
robot -v BMC_HOST:10.0.0.124 -v LAN_CHANNEL:8 -d logs/ipmi src/robot/ipmi/lan.robot
```

**A sensor test fails on a name**
Sensor names are board-specific. List them with
`ipmitool -I lanplus -H <host> -U admin -E sensor list`, then set
`-v SENSOR_TEMP:<name>` / `-v SENSOR_VOLT:<name>` (or edit `bmc.resource`).
