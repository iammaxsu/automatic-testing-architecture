# Architecture Decisions

Consolidated record of architectural decisions for the Automatic Testing
Architecture framework. Newest entries first. Each entry is dated and states
the context, the decision, and its consequences, so the *why* survives even
after the code that motivated it changes.

> This file is the intended home for decisions currently scattered across the
> Claude.ai "Automatic Testing Architecture" project chats (see CLAUDE.md).
> Migrate them here as they are needed.

---

## ADR-0001 — Out-of-band IPMI test engine: wrap the ipmitool CLI

**Date:** 2026-06-18
**Status:** Accepted
**Area:** BMC / IPMI testing (Phase 1); `src/robot/lib/BMCLibrary.py`,
`src/robot/ipmi/` (per-area suites), `src/bash-shell/bmc_sensor_test.sh`

### Context

Phase 1 covers out-of-band BMC testing over IPMI 2.0 (lanplus). We wanted
**structured returns** (read a sensor as an object, not by parsing ipmitool's
`|`-delimited text) and evaluated the Kontron
[`robotframework-ipmilibrary`](https://github.com/kontron/robotframework-ipmilibrary)
(built on [`python-ipmi`](https://github.com/kontron/python-ipmi)) as the
engine. A time-boxed evaluation spike (`src/robot/spike`, removed after this
decision — see git history at commit `8d99e59`) tested three connection paths
against the real DUT BMC (`10.0.0.124`, Manufacturer ID 24339):

| Probe | Path | Result |
|-------|------|--------|
| A | `ipmitool` CLI, lanplus (control) | **PASS** (0.1 s) |
| B | python-ipmi + ipmitool backend, lanplus | FAIL — `DecodingError: Data too short for message` |
| C | python-ipmi native `rmcp` (IPMI 1.5) | FAIL — `cc=0xcc Invalid data field in Request` |

The Kontron RF suite failed 2/2 for the same underlying reasons. Two
findings from reading the libraries' source:

1. The RF library's LAN connection keywords default to **IPMI 1.5** (native
   `rmcp` = Get Session Challenge / MD5; the ipmitool backend defaults to
   `-I lan`, and the keyword does not expose `lanplus`). Many modern BMCs
   disable 1.5.
2. Even via the ipmitool backend at lanplus, **python-ipmi's own response
   decoder** rejected this BMC's `Get Device ID` reply. The library meant to
   *remove* text-parsing fragility introduced its own decode fragility.

Meanwhile the plain `ipmitool` CLI works perfectly, and the existing
ipmitool-wrapping `BMCLibrary.py` had already run a 60-hour sensor soak
against this exact BMC with zero communication failures.

### Decision

Drive out-of-band IPMI by **wrapping the `ipmitool` CLI** in
`BMCLibrary.py`. Do **not** adopt python-ipmi or the Kontron RF library.

### Consequences

- **+** Standardises on the only path empirically proven against our BMC.
- **+** One transport for both the bash (`bmc_sensor_test.sh`) and Robot
  (`BMCLibrary.py`) layers; consistent behaviour and retry/timeout handling.
- **+** No extra runtime dependency; `ipmitool` is already required.
- **−** We parse ipmitool text output (per-command parsers in
  `BMCLibrary.py`), and must keep those parsers robust as coverage grows.
- **Scope kept:** test-case coverage is still modelled on the
  [openbmc-test-automation](https://github.com/openbmc/openbmc-test-automation)
  and [Arm SBMR-ACS](https://github.com/ARM-software/sbmr-acs) IPMI suites; only
  the *engine* underneath differs.
- **Revisit if:** the BMC firmware changes, or a future phase needs a path
  python-ipmi handles better. Re-running the three probes above (recoverable
  from git history) re-decides it in ~1 minute.
