# CI / Self-Hosted Runner Setup

This document describes how the test framework is driven from GitHub Actions
across the heterogeneous lab topology, and what you must set up by hand.

## Topology recap

```
push / PR ──► GitHub
               │
               ├─► validate            (GitHub-hosted; no hardware)
               │
               ├─► vserver runner ──► ansible ──► DUT1 (Linux)
               │
               └─► pi runner ───────► Python (GPIO/relay) ──► DUT2 power tests
                                  └──► SSH/SCP ─────────────► DUT2 PowerShell
```

| Runner label | Machine | Handles |
|--------------|---------|---------|
| *(hosted)*   | GitHub  | `validate.yml` — compile + dry-run, no DUT |
| `pi`         | Pi      | DUT2 power_cycle / reboot (`dut2-power.yml`) |
| `vserver`    | vserver | DUT1 ansible tests (`dut1-linux.yml`, *pending*) |

No GitHub Secrets are required: each runner already holds the SSH keys it
needs (Pi → DUT2; vserver → DUT1). Internal IPs are passed as workflow inputs,
not secrets.

## Installing a self-hosted runner

Do this once on the Pi, and once on the vserver. Get the download URL and
registration token from:

> GitHub repo → Settings → Actions → Runners → **New self-hosted runner**

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o runner.tar.gz -L <URL-from-GitHub>          # pick the Linux ARM64 build on the Pi
tar xzf runner.tar.gz

# Register. Set the label to match the workflow's runs-on:
./config.sh \
  --url https://github.com/iammaxsu/automatic-testing-architecture \
  --token <TOKEN-from-GitHub> \
  --labels pi            # use "vserver" on the vserver

# Run as a service so it survives reboots:
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

The runner must run as a user that:
- on the **Pi**: can access the GPIO and holds the SSH key for DUT2;
- on the **vserver**: can run `ansible-playbook` with the lab inventory and
  holds the SSH key for DUT1.

Verify the runner shows **Idle** under Settings → Actions → Runners.

## Workflows

### `validate.yml` — runs now, no setup needed
Triggers on every push / PR. Compiles all Python, syntax-checks every shell
script, and dry-runs the composite runner. Pure software; no DUT touched.

### `dut2-power.yml` — needs the `pi` runner
Manual dispatch (Actions → "DUT2 power tests (Pi)" → Run workflow). Inputs:
power/reboot cycle counts, DUT2 host, SSH user, PSU type. Serialised by a
`dut2-hardware` concurrency group. Uploads `logs/**` (result.json + HTML) as a
build artifact.

## Pending — require decisions before wiring

### DUT1 (Linux via ansible) — `ansible-playbooks/` not yet reconciled
The playbooks were carried over from the legacy `Test-Automation` repo and do
not match this repo's layout:

1. `01-deploy.yml` copies from `{{ playbook_dir }}/../scripts/<name>.sh`, but
   the bash scripts live in `src/bash-shell/`, not `scripts/`
   (`scripts/` here holds only `stats.py` / `make_dashboard.py`).
2. Its `scripts:` list includes `test_warning_daemon.sh`, which does not exist
   in `src/bash-shell/` either.
3. The `test_machines` inventory is not in the repo — it lives on the vserver.

Reconciling the playbook source path and script set (and deciding whether the
inventory should be committed or stay vserver-local) is a prerequisite for a
DUT1 CI workflow.

### DUT2 PowerShell — async, not a synchronous CI job
`reboot.ps1` is a DUT-local endurance test driven by Task Scheduler: it reboots
DUT2 repeatedly over hours, so an SSH session that launches it cannot wait for
completion. A CI workflow for it needs a "deploy → kick off → poll the session
file / status until done → collect artifacts" model, not a single blocking SSH
call. One-shot PowerShell tests (e.g. `dev_detect.ps1`) fit the synchronous
model and could be automated first.

The USB-stick transfer can be retired regardless: DUT2 already runs OpenSSH
with the Pi's public key installed (`setup_dut.ps1`), so scripts can be copied
with `scp` and invoked over SSH from the Pi.
