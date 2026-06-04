# CI / Self-Hosted Runner Setup

This document describes how the test framework is driven from GitHub Actions
across the heterogeneous lab topology, and what you must set up by hand.

## Topology recap

```
push / PR ──► GitHub
               │
               ├─► validate            (GitHub-hosted; no hardware)
               │
               ├─► vserver runner ──► rsync scripts ──► ansible ──► DUT1 (Linux)
               │
               └─► pi runner ───────► Python (GPIO/relay) ──────────► DUT2 power tests
```

| Runner label | Machine | Handles |
|--------------|---------|---------|
| *(hosted)*   | GitHub  | `validate.yml` — compile + dry-run, no DUT |
| `vserver`    | vserver | DUT1 ansible tests (`dut1-linux.yml`) |
| `pi`         | Pi      | DUT2 power_cycle / reboot (`dut2-power.yml`) |

No GitHub Secrets are required. Each runner uses its local SSH keys and
`ansible.cfg`; internal IPs are entered as workflow dispatch inputs.

## Installing a self-hosted runner

Do this **once on the Pi** and **once on the vserver**. Get the exact download
URL and registration token from:

> GitHub repo -> Settings -> Actions -> Runners -> **New self-hosted runner**

Choose **Linux ARM64** for the Pi; **Linux x64** for the vserver.

```bash
# Run on each machine (fill in URL and TOKEN from the GitHub page above)
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o runner.tar.gz -L <URL-from-GitHub>
tar xzf runner.tar.gz

# Register with a label matching the workflow's runs-on:
./config.sh \
  --url https://github.com/iammaxsu/automatic-testing-architecture \
  --token <TOKEN-from-GitHub> \
  --labels pi          # use "vserver" on the vserver

# Install and start as a systemd service (survives reboots):
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

Verify the runner shows **Idle** under Settings -> Actions -> Runners before
triggering a workflow.

### Runner user requirements

| Machine | The runner user must be able to ... |
|---------|--------------------------------------|
| Pi      | access GPIO; SSH into DUT2 (key already in `~/.ssh/`) |
| vserver | run `ansible-playbook`; SSH into DUT1; read/write `~/Downloads/test-automation_ansible/` |

The default install creates a `runner` user. If `ansible-playbook` and the SSH
keys are under `maxsu`, either install the runner as `maxsu` or copy the keys
to the `runner` user's `~/.ssh/`.

## Workflows

### `validate.yml` -- runs immediately, no setup needed
Triggers on every push / PR (GitHub-hosted runner). Compiles all Python,
syntax-checks every shell script, and dry-runs `run_tests.sh`. No DUT touched.

### `dut1-linux.yml` -- needs the `vserver` runner
Manual dispatch (Actions -> "DUT1 Linux tests (vserver/ansible)" -> Run workflow).

Inputs: `test` (disk / net / both), `loops` (bLoops count).

Flow:
1. `rsync src/bash-shell/*.sh` to `~/Downloads/test-automation_ansible/scripts/`
   (updates scripts in-place; does **not** delete `test_warning_daemon.sh` or
   other vserver-local scripts that are not yet in this repo).
2. `ansible-playbook playbooks/01-deploy.yml` -- deploy to DUT1.
3. `ansible-playbook playbooks/02-run-disk-test.yml -e bLoops=N` and/or
   `03-run-net-test.yml`.
4. Uploads `**/*.log` as a build artifact.

### `dut2-power.yml` -- needs the `pi` runner
Manual dispatch. Inputs: power/reboot cycle counts, DUT2 host, SSH user, PSU type.
Serialised by a `dut2-hardware` concurrency group. Uploads `logs/**` as artifact.

## Pending -- DUT2 PowerShell

`reboot.ps1` is a DUT-local endurance test driven by Task Scheduler and runs
over hours. It cannot be modelled as a single synchronous SSH call. A CI workflow
will need a "deploy -> start -> poll session file -> collect artifacts" approach.
One-shot scripts such as `dev_detect.ps1` fit the synchronous model and could be
automated first; USB transfer can be replaced by `scp` from the Pi at any time.
