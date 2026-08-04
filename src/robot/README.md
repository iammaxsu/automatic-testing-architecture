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
./src/robot/run.sh -H 10.0.0.124          # read-only IPMI suite
```

`run.sh` prints the output directory and writes to
`logs/<dut>/<session>/report.html` — open that. (See "Output layout" below;
each run gets its own directory, so nothing is overwritten.)

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

The read-only areas are safe on a DUT that is in use. `power.robot` (power
control) is **gated** — its tests SKIP unless you enable them (see below), so
the default run never disrupts the DUT.

Use `run.sh` — it builds a per-DUT, per-session output directory (see
"Output layout") so runs never overwrite each other:

```bash
# read-only areas + gated power (power SKIPS unless enabled) = 18 tests
./src/robot/run.sh -H 10.0.0.124

# one area, by file
./src/robot/run.sh -H 10.0.0.124 -s src/robot/ipmi/lan.robot

# one area, by tag (pass-through robot args go after --)
./src/robot/run.sh -H 10.0.0.124 -- --include fru
```

Raw `robot` still works if you prefer — just pass your own `-d` so you do not
overwrite a previous run, e.g.
`robot -v BMC_HOST:10.0.0.124 -d logs/10.0.0.124/manual src/robot/ipmi/`.

Areas / tags: `device-id`, `sensor`, `sel`, `chassis`, `fru`, `sdr`, `lan`, `user`, `power` (gated).

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

### Power-control tests (gated, destructive)

`src/robot/ipmi/power.robot` powers the DUT **off / cycles** it (modelled on
`power_cycle.py`): perform the action, verify recovery, measure the time. It is
gated off by default — every test SKIPS unless you pass
`-v POWER_TESTS_ENABLED:True` — so it never runs during a normal read-only
sweep. Run it deliberately, against a DUT that can tolerate a reboot:

```bash
./src/robot/run.sh -H 10.0.0.124 -s src/robot/ipmi/power.robot -- \
    -v POWER_TESTS_ENABLED:True -v DUT_HOST:<dut-os-ip> -v POWER_CYCLES:1
```

Optional overrides:

| Variable | Default | Meaning |
|----------|---------|---------|
| `POWER_TESTS_ENABLED` | `False` | must be `True` for any power test to run |
| `POWER_CYCLES` | `1` | how many times to power-cycle |
| `NEW_SESSION` | `False` | `True` forces a fresh session, ignoring saved progress |
| `DUT_HOST` | *(empty)* | if set, also wait for the DUT OS to answer ping after power-on (real boot, not just BMC power state) |
| `POWER_ON_TIMEOUT` | `120` | seconds to wait for chassis power to return |
| `DUT_BOOT_TIMEOUT` | `300` | seconds to wait for DUT OS liveness |

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

The report header shows the **BMC identity** captured at suite setup — host,
firmware revision, IPMI version, manufacturer and product — so you can always
tell which BMC/firmware a run tested. The bash soak records the same firmware
revision in its `result.json` (`bmc_firmware`).

### Output layout (LOG025)

`run.sh` writes each run to its own directory, keyed by DUT and session:

```
logs/
└── 10.0.0.124/                 # <dut>  (BMC host/IP; ':' and '/' -> '_')
    ├── 20260729T142530/        # <session_id>  (ISO 8601 basic start time)
    │   ├── report.html
    │   ├── log.html
    │   └── output.xml
    └── 20260729T161004/        # a later run — the earlier one is untouched
```

So re-running the same suite never overwrites a prior result, and different
DUTs land in different top-level folders. The bash soak follows the same
convention: `logs/<dut>/bmc_sensor_<session>/`.

### Resume for endurance runs (LOG023 / LOG026)

The power-cycle endurance test records progress after every cycle in

```
logs/<dut>/power_cycle_ipmi_session.json
```

Three rules, all verified:

1. **Interrupted run resumes.** Re-run the *same* cycle count and it continues
   where it stopped (e.g. stopped at 100/300 → next run does 101…300).
2. **The count you ask for is the count you get.** Asking for a *different*
   count starts a **new** session for that number (with a WARN in the log) —
   it never silently finishes the old plan.
3. **Deleting the logs tree is a full reset.** The session file lives inside
   `logs/`, so `rm -rf logs/` (or just the per-DUT folder) makes the next run
   behave exactly like a first run.

Force a fresh session without deleting anything: `-v NEW_SESSION:True`.
Session state is per-DUT, so runs against different BMCs never interfere.

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
