# IPMI engine evaluation spike

A **throwaway** experiment (XP "spike"): time-boxed code whose only job is
to answer one technical question with evidence, so we pick the Phase 1 IPMI
engine instead of guessing. Delete it once the decision is locked.

## The question

For Phase 1 (BMC / IPMI 2.0 testing) we want **structured returns** — read a
sensor as an object, not by parsing `ipmitool`'s `|`-delimited text like the
current `BMCLibrary.py` does. The candidate is the Kontron
[`robotframework-ipmilibrary`](https://github.com/kontron/robotframework-ipmilibrary)
(built on [`python-ipmi`](https://github.com/kontron/python-ipmi)). But there
is a catch found while reading their source:

| Path | IPMI version | Notes |
|------|--------------|-------|
| RF `Open Ipmi Rmcp Connection` → python-ipmi native `rmcp` | **1.5 only** | Get Session Challenge / Activate Session / MD5. No RMCP+/RAKP. |
| RF `Open Ipmi Lan Connection` → `ipmitool` backend | **1.5** (`-I lan`) | Keyword does not expose `lanplus`. |
| python-ipmi `ipmitool` backend, `interface_type='lanplus'` | **2.0** | Works, but only when *we* force it (not via the RF keywords). |
| `ipmitool -I lanplus` CLI | **2.0** | What your BMC is already driven with. |

Your BMC is reached with `ipmitool -I lanplus` (IPMI 2.0). Many modern BMCs
**disable IPMI 1.5** for security. So the Kontron RF library may fail to
connect out of the box even though the BMC is perfectly healthy. This spike
measures exactly which paths work on **your** board.

## Run it (on the vserver, which can reach the BMC)

```bash
export IPMI_PASSWORD='your-bmc-password'
cd src/robot/spike
./run_spike.sh -H 10.0.0.124 -U admin
```

It creates a disposable venv, installs the stack, dumps the real keyword
list, then runs two layers:

1. **`spike_probe.py`** — the python-ipmi layer + an `ipmitool` CLI control:
   - **Probe A** `ipmitool` CLI, lanplus — baseline: is the BMC reachable at all?
   - **Probe B** python-ipmi + ipmitool backend, **lanplus (2.0)** — the best candidate.
   - **Probe C** python-ipmi native `rmcp` (**1.5**) — does this BMC allow 1.5?
2. **`spike_ipmi.robot`** — the Kontron RF library's two connection keywords,
   proving whether the expansion works *as-is*.

## Read the result — decision matrix

The `ENGINE DECISION` block in `spike_out/spike_probe.out` says which case you hit:

| Outcome | Phase 1 engine |
|---------|----------------|
| **Probe B passes** (likely) | Build on **python-ipmi + ipmitool backend (lanplus)** for structured 2.0 returns. The RF suite probably FAILED (it's 1.5) → we wrap python-ipmi in our own thin RF keyword library, or subclass Kontron's to force lanplus. |
| **Probe C / RF suite passes** | BMC allows 1.5 → Kontron library is usable as-is, but 1.5 auth is weak; prefer B if you can. |
| **Only Probe A passes** | Both python-ipmi paths blocked → stay with the proven approach: extend `BMCLibrary.py` (wrap the `ipmitool` CLI). |
| **Nothing passes** | Connectivity/credentials, not an engine choice — fix host/user/`IPMI_PASSWORD`/port 623 and re-run. |

## What to send back

`spike_out/spike_probe.out` and `spike_out/rf_report.html`. From those we lock
the engine and start Phase 1 properly. `spike_out/ipmilibrary_keywords.txt` is
the authoritative keyword list we'll build the real suites from regardless of
which engine wins.

## Notes

- Password is read only from `IPMI_PASSWORD` (never a CLI arg, never logged).
- Everything here is disposable: `spike_out/` (incl. the venv) can be deleted.
- No hardware needed to develop the *next* step: `ipmisim` (a pyghmi-based fake
  IPMI server) can stand in for CI, like the mock we used for the sensor soak.
