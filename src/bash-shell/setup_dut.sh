#!/usr/bin/env bash
# setup_dut.sh — Linux DUT one-time pre-test setup for automatic-testing-architecture.
#
# Bootstraps a fresh Ubuntu installation so it can participate in automated
# power-cycle and reliability tests driven from a Raspberry Pi controller.
# This is the Linux counterpart of setup_dut.ps1 (SET005 / SET007).
#
# What this script does:
#   1. Installs and enables OpenSSH Server (sshd), autostart on boot
#   2. Opens firewall (ufw, if active): TCP 22 (SSH) and ICMP echo (ping)
#   3. Installs the Pi controller's SSH public key into the test user's
#      ~/.ssh/authorized_keys (passwordless, BatchMode-compatible login)
#   4. Grants the test user NOPASSWD sudo for shutdown/reboot/poweroff
#      (required by shutdown.py / reboot.py: "sudo shutdown -h now", "sudo reboot")
#   5. Disables sleep/suspend/hibernate (systemd targets + logind idle action)
#   6. Disables unattended-upgrades automatic reboot
#   7. Sets GRUB_TIMEOUT=0 and GRUB_RECORDFAIL_TIMEOUT=0 so every boot proceeds
#      unattended, even after an unclean shutdown (no operator at the console)
#   8. (Optional) Registers a systemd oneshot service to run dev_detect.sh at boot
#   9. Ensures Python 3 is present and downloads report.py for HTML rendering
#
# This script is intentionally idempotent: running it multiple times is safe.
#
# IMPORTANT — chicken-and-egg note:
# This script must be run once locally (physical console or an existing SSH
# session with a password) before passwordless/BatchMode automated testing
# can begin.  After it runs, the RPi controller can reach the DUT over SSH
# for all subsequent tests (NET002 / FWK032).
#
# Usage:
#   sudo ./setup_dut.sh [options]
#
# Options (all optional — zero-argument runs are supported, FWK034):
#   --test-user USERNAME       Account the Pi controller logs in as.
#                               Auto-detected when omitted: the sudo invoker
#                               ($SUDO_USER), else the first regular human account
#                               (UID >= 1000 with a /home directory).
#   --pi-key "ssh-ed25519 AAAA...key... pi@raspberrypi"
#                               Public key of the Pi controller (contents of
#                               ~/.ssh/id_ed25519.pub on the Pi). Installed into
#                               --test-user's authorized_keys (idempotent).
#                               Auto-detected when omitted: a single *.pub file
#                               sitting next to this script, else an interactive
#                               paste prompt when run on a terminal.
#   --pi-key-file PATH          Same as --pi-key but read the key from a file.
#   --dev-detect-script PATH    Path to dev_detect.sh to register as a boot-time
#                               systemd service. Default: auto-detect a sibling
#                               dev_detect.sh next to this script (FWK034).
#   --dev-detect-delay SEC      Seconds to sleep inside the service before
#                               running dev_detect.sh (default: 30).
#   -h, --help                  Show this help and exit.
#
# Examples:
#   # Zero-argument run: SSH + firewall + sudoers + power settings,
#   # and dev_detect.sh registered if it sits next to this script (FWK034).
#   sudo ./setup_dut.sh
#
#   # Install the Pi's public key for passwordless login as 'adlink'
#   sudo ./setup_dut.sh --test-user adlink --pi-key "ssh-ed25519 AAAA...key... pi@raspberrypi"
#
#   # Same, reading the key from a file copied alongside this script
#   sudo ./setup_dut.sh --test-user adlink --pi-key-file ./pi_id_ed25519.pub

set -Eeuo pipefail

_script_ver="00.00.02"

# ---------- 0. Root privilege check (FWK033) ----------------------------------
# MUST be the first executable action, before any other output, so an operator
# who launched a non-root shell sees a single clear error instead of a wall of
# step messages with silently-skipped privileged operations.
if [[ "$(id -u)" -ne 0 ]]; then
  echo ""
  echo "============================================================"
  echo "  ERROR: root privileges required."
  echo "============================================================"
  echo "  setup_dut.sh configures the test environment and MUST run"
  echo "  as root.  NOTHING has been changed."
  echo ""
  echo "  Re-run with:  sudo ./setup_dut.sh [options]"
  echo "============================================================"
  exit 1
fi

# ---------- Console helpers ----------------------------------------------------
_step() { echo; echo "== $* =="; }
_ok()   { echo "  [OK]   $*"; }
_skip() { echo "  [SKIP] $*"; }
_warn() { echo "  [WARN] $*"; }

echo "setup_dut.sh v${_script_ver}"

# ---------- Argument parsing ----------------------------------------------------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_script_root="$(cd "$(dirname "${_entry}")" && pwd)"

# Reusable apply/restore logic lives in function.sh (single source of truth).
# function.sh ships alongside the test scripts, so it is always present on a DUT
# that runs tests; setup_dut.sh is deployed next to it.
_fn_lib="${_script_root}/function.sh"
if [[ ! -f "${_fn_lib}" ]]; then
  echo "ERROR: function.sh not found next to setup_dut.sh (${_fn_lib})." >&2
  echo "       Copy function.sh into the same folder and re-run." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${_fn_lib}"
# Guard against a stale function.sh that predates the test_env_* helpers:
# fail fast with a clear message instead of a cryptic 'command not found'.
if ! declare -F test_env_restore_all >/dev/null 2>&1; then
  echo "ERROR: function.sh next to setup_dut.sh is outdated —" >&2
  echo "       it is missing the test_env_* helpers (test_env_restore_all)." >&2
  echo "       Update function.sh on this DUT to match setup_dut.sh, then re-run." >&2
  exit 1
fi

_mode="setup"           # setup | restore
_test_user=""           # empty = auto-detect after parsing (see below)
_pi_key=""
_pi_key_source=""       # human-readable origin of the key, for log messages
_dev_detect_script=""
_dev_detect_delay=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore)           _mode="restore"; shift ;;
    --test-user)         _test_user="$2"; shift 2 ;;
    --pi-key)            _pi_key="$2"; _pi_key_source="--pi-key argument"; shift 2 ;;
    --pi-key-file)       _pi_key="$(cat "$2")"; _pi_key_source="$2"; shift 2 ;;
    --dev-detect-script) _dev_detect_script="$2"; shift 2 ;;
    --dev-detect-delay)  _dev_detect_delay="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,60p' "${_entry}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# ---------- Restore mode: undo test-environment mutations and exit ------------
# Reverts only the "temporary, for-testing" changes (logind power-key/lid/idle
# behavior, masked sleep targets). Framework infrastructure (SSH key, sudoers,
# dev-detect autorun) is intentionally left in place. This entry point is what
# the Pi calls over SSH once a test session completes, or what an operator runs
# by hand when retiring the DUT.
if [[ "${_mode}" == "restore" ]]; then
  echo "Restore mode: reverting DUT test-environment changes…"
  echo
  test_env_restore_all
  echo
  echo "  Restore complete. Re-apply test settings any time with: sudo ./setup_dut.sh"
  exit 0
fi

# ---------- Auto-detect sibling dev_detect.sh (FWK034) --------------------------
if [[ -z "${_dev_detect_script}" ]]; then
  _sibling="${_script_root}/dev_detect.sh"
  if [[ -f "${_sibling}" ]]; then
    _dev_detect_script="${_sibling}"
    echo "         Auto-detected dev_detect.sh : ${_sibling}"
  fi
fi

# ---------- Auto-detect the test user (FWK034) ---------------------------------
# The account the Pi controller logs in as. Priority:
#   1. --test-user (explicit)
#   2. the sudo invoker ($SUDO_USER), when it is a real (non-root) account
#   3. the first regular human account (UID 1000-59999 with a /home directory)
if [[ -z "${_test_user}" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    _test_user="${SUDO_USER}"
    echo "         Auto-detected test user (sudo invoker)      : ${_test_user}"
  else
    _test_user="$(getent passwd \
      | awk -F: '$3>=1000 && $3<60000 && $6 ~ /^\/home\// {print $1; exit}')"
    if [[ -n "${_test_user}" ]]; then
      echo "         Auto-detected test user (first human account): ${_test_user}"
    else
      echo "ERROR: could not auto-detect a test user; pass --test-user USERNAME" >&2
      exit 1
    fi
  fi
fi

_target_home="$(getent passwd "${_test_user}" | cut -d: -f6)"
if [[ -z "${_target_home}" ]]; then
  echo "ERROR: user '${_test_user}' not found (pass --test-user)" >&2
  exit 1
fi

# ---------- Auto-detect the Pi public key (FWK034) -----------------------------
# Resolve the controller's SSH public key when --pi-key/--pi-key-file was not
# given. Priority:
#   1. explicit --pi-key / --pi-key-file (handled above)
#   2. a single *.pub file deployed next to this script (the Pi can drop its
#      public key into the same folder it copies the scripts into)
#   3. an interactive paste prompt, only when running attached to a terminal
# If none is found the SSH-key step reports it and continues (see step 3).
if [[ -z "${_pi_key}" ]]; then
  shopt -s nullglob
  _pub_candidates=( "${_script_root}"/*.pub )
  shopt -u nullglob
  if (( ${#_pub_candidates[@]} == 1 )); then
    _pi_key="$(cat "${_pub_candidates[0]}")"
    _pi_key_source="${_pub_candidates[0]}"
    echo "         Auto-detected Pi public key file             : ${_pub_candidates[0]}"
  elif (( ${#_pub_candidates[@]} > 1 )); then
    echo "         Multiple *.pub files next to the script — not guessing:"
    printf '           - %s\n' "${_pub_candidates[@]}"
    echo "         Pass --pi-key-file to choose one."
  fi

  if [[ -z "${_pi_key}" && -t 0 ]]; then
    echo
    echo "  No Pi public key supplied and none found next to the script."
    echo "  On the Raspberry Pi controller run:  cat ~/.ssh/id_ed25519.pub"
    echo "  then paste that single line here (or press Enter to skip):"
    read -r -p "  Pi public key> " _pasted || true
    if [[ -n "${_pasted:-}" ]]; then
      _pi_key="${_pasted}"
      _pi_key_source="interactive paste"
    fi
  fi
fi


# ---------- 1. OpenSSH Server ----------------------------------------------------

_step "1 / 8  OpenSSH Server"

if command -v sshd >/dev/null 2>&1; then
  _skip "openssh-server already installed"
else
  echo "  Installing openssh-server..."
  apt-get update -qq
  apt-get install -y -qq openssh-server
  _ok "openssh-server installed"
fi

systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
_ok "sshd running, startup = enabled"


# ---------- 2. Firewall: SSH (TCP 22) and ICMP ping -------------------------------

_step "2 / 8  Firewall rules"

if command -v ufw >/dev/null 2>&1; then
  _ufw_status="$(ufw status | head -1)"
  if [[ "${_ufw_status}" == "Status: active" ]]; then
    if ufw status | grep -qE '^(22|OpenSSH)\b'; then
      _skip "ufw rule already exists: SSH (22)"
    else
      ufw allow OpenSSH >/dev/null
      _ok "ufw rule added: SSH (OpenSSH/22)"
    fi
    # Ubuntu's default ufw before.rules already accepts ICMP echo-request;
    # nothing to add unless the operator has hardened it further.
    _ok "ufw active — ICMP echo is allowed by the default before.rules"
  else
    _skip "ufw is inactive — all ports already reachable, nothing to open"
  fi
else
  _skip "ufw not installed — no host firewall to configure"
fi


# ---------- 3. SSH key: install Pi public key for passwordless login -------------
#
# function.py / liveness.py / shutdown.py all use `ssh -o BatchMode=yes`, which
# never falls back to a password prompt. Without the Pi's public key in
# ~/.ssh/authorized_keys, every SSH call from the Pi (uname -s, query session /
# wall, shutdown, reboot) fails immediately with exit 255 — which is the
# "DUT OS detected: windows (uname -s exit 255)" symptom on a Linux DUT.

_step "3 / 8  SSH key for ${_test_user}"

_ssh_dir="${_target_home}/.ssh"
_auth_file="${_ssh_dir}/authorized_keys"

# Count keys already authorized (non-comment, non-blank lines).
_existing_keys=0
if [[ -f "${_auth_file}" ]]; then
  _existing_keys="$(grep -cE '^[^#[:space:]]' "${_auth_file}" 2>/dev/null)" || true
  _existing_keys="${_existing_keys:-0}"
fi

if [[ -n "${_pi_key}" ]]; then
  mkdir -p "${_ssh_dir}"
  chmod 700 "${_ssh_dir}"
  touch "${_auth_file}"
  chmod 600 "${_auth_file}"

  if grep -qF "${_pi_key}" "${_auth_file}" 2>/dev/null; then
    _skip "Pi SSH public key already authorized (${_pi_key_source}) — nothing to do"
  else
    echo "${_pi_key}" >> "${_auth_file}"
    _ok "Pi SSH public key installed from ${_pi_key_source}"
  fi

  chown -R "${_test_user}:${_test_user}" "${_ssh_dir}"
  _ok "ownership/permissions fixed: ${_ssh_dir} (700), authorized_keys (600)"
  echo "         Test from the Pi: ssh ${_test_user}@<this-host>"
elif (( _existing_keys > 0 )); then
  # No key resolved this run, but the account already has authorized keys —
  # treat SSH authorization as already configured and move on.
  _skip "SSH authorization already present: ${_existing_keys} key(s) in ${_auth_file}"
  echo "         No --pi-key given and no *.pub beside the script; assuming this DUT"
  echo "         is already authorized. Pass --pi-key to add/verify a specific key."
else
  _warn "No SSH key authorized for ${_test_user}, and none was supplied or found"
  echo "         Passwordless SSH from the Pi will NOT work until a key is added."
  echo "         On the Pi:   cat ~/.ssh/id_ed25519.pub"
  echo "         Then either drop that .pub file next to setup_dut.sh and re-run,"
  echo "         or:  sudo ./setup_dut.sh --test-user ${_test_user} --pi-key \"<key>\""
fi


# ---------- 4. NOPASSWD sudo for shutdown / reboot / restore --------------------
#
# shutdown.py's SSH shutdown method and reboot.py both run "sudo shutdown -h now"
# / "sudo reboot" over a non-interactive SSH session (config._OS_SHUTDOWN_CMD /
# _OS_REBOOT_CMD for dut_os=linux). Without NOPASSWD these hang waiting for a
# password that BatchMode will never supply.
# The restore helper is also included so the Pi can trigger test-environment
# restore over SSH when a test session completes.

_step "4 / 8  NOPASSWD sudo (shutdown / reboot / poweroff / restore)"

_restore_helper="/usr/local/lib/automatic-testing/dut-restore-test-env"
_sudoers_file="/etc/sudoers.d/99-automatic-testing-${_test_user}"
_sudoers_line="${_test_user} ALL=(ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /sbin/poweroff, /usr/sbin/shutdown, /usr/sbin/reboot, /usr/sbin/poweroff, ${_restore_helper}"

if [[ -f "${_sudoers_file}" ]] && grep -qF "${_sudoers_line}" "${_sudoers_file}"; then
  _skip "NOPASSWD sudo already configured: ${_sudoers_file}"
else
  echo "${_sudoers_line}" > "${_sudoers_file}.tmp"
  chmod 440 "${_sudoers_file}.tmp"
  if visudo -cf "${_sudoers_file}.tmp" >/dev/null 2>&1; then
    mv "${_sudoers_file}.tmp" "${_sudoers_file}"
    _ok "NOPASSWD sudo configured: ${_sudoers_file}"
  else
    rm -f "${_sudoers_file}.tmp"
    _warn "visudo validation failed — sudoers file NOT written"
  fi
fi

# ---------- 4b. Deploy DUT restore helper ----------------------------------------
#
# A minimal script installed at a fixed well-known path so the Pi can call
#   ssh user@dut "sudo /usr/local/lib/automatic-testing/dut-restore-test-env"
# and reverse the test-environment changes without knowing where setup_dut.sh
# lives. This is the only file placed in /usr/local; everything else stays in the
# user's chosen deployment folder.

_restore_helper_dir="$(dirname "${_restore_helper}")"
mkdir -p "${_restore_helper_dir}"

cat > "${_restore_helper}" <<'RESTORE_HELPER'
#!/usr/bin/env bash
# DUT test-environment restore helper — auto-installed by setup_dut.sh.
# Reverses only the test-specific logind and sleep-target changes made by
# setup_dut.sh. Framework infrastructure (SSH key, sudoers, dev-detect autorun)
# is intentionally left in place.
# Called by the Pi over SSH on test-session complete, or manually via:
#   sudo ./setup_dut.sh --restore
set -euo pipefail
echo "[restore] Removing logind drop-in…"
rm -f /etc/systemd/logind.conf.d/99-automatic-testing.conf
for k in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked \
          HandleSuspendKey HandleHibernateKey IdleAction \
          HandlePowerKey HandlePowerKeyLongPress; do
  sed -i "/^${k}=/d" /etc/systemd/logind.conf 2>/dev/null || true
done
systemctl restart systemd-logind
echo "[restore] Unmasking sleep targets…"
systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
echo "[restore] DUT test-environment restored."
RESTORE_HELPER

chmod +x "${_restore_helper}"
_ok "Restore helper deployed: ${_restore_helper}"


# ---------- 5. Power management: disable sleep / suspend / hibernate -------------
#
# The apply/restore logic lives in function.sh (test_env_* helpers) so that
# `setup_dut.sh` (apply) and `setup_dut.sh --restore` (revert) share one source
# of truth. All logind settings go into a single drop-in file
# (/etc/systemd/logind.conf.d/99-automatic-testing.conf), never the main
# logind.conf, so the change is fully reversible. HandlePowerKey=poweroff makes
# logind handle the ATX short-press immediately (kernel→logind→poweroff),
# bypassing the GNOME session manager's interactive shutdown dialog that causes
# HANG_SHUTDOWN during power_cycle.py tests.

_step "5 / 8  Power management (no sleep / suspend / hibernate)"

test_env_sleep_mask
test_env_logind_apply
echo "         Restore: sudo ./setup_dut.sh --restore"


# ---------- 6. Disable unattended-upgrades automatic reboot -----------------------

_step "6 / 9  Unattended-upgrades automatic reboot"

_uu_conf="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ -f "${_uu_conf}" ]]; then
  if grep -qE '^\s*Unattended-Upgrade::Automatic-Reboot\s+"false";' "${_uu_conf}"; then
    _skip "Automatic-Reboot already disabled in ${_uu_conf}"
  else
    if grep -qE '^\s*//?\s*Unattended-Upgrade::Automatic-Reboot\b' "${_uu_conf}"; then
      sed -i -E 's@^\s*//?\s*(Unattended-Upgrade::Automatic-Reboot)\s+".*";@\1 "false";@' "${_uu_conf}"
    else
      echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> "${_uu_conf}"
    fi
    _ok "Unattended-Upgrade::Automatic-Reboot set to false"
  fi
else
  _skip "unattended-upgrades not installed — nothing to disable"
fi


# ---------- 7. GRUB: unattended boot (no operator at the console) ----------------
#
# reboot.py / power_cycle.py poll ping/SSH after issuing a reboot, bounded by
# BOOT_TIMEOUT_SEC. While the DUT is parked at the GRUB menu the kernel has not
# loaded yet — no network stack exists — so ping/SSH cannot succeed; this is
# dead time the test simply burns through, and a menu that never auto-boots
# (no one is present to press Enter) makes every such cycle time out as NO_BOOT.
#
# Two independent GRUB settings can each cause a menu to appear and wait
# indefinitely:
#   - GRUB_TIMEOUT: the normal "show menu for N seconds" countdown.
#   - GRUB_RECORDFAIL_TIMEOUT (Ubuntu-specific): overrides GRUB_TIMEOUT and
#     defaults to -1 (wait forever) whenever the previous boot did not reach
#     the "boot ok" marker — e.g. a prior test cycle's reboot/power-cycle did
#     not shut down cleanly. This is the most likely reason the menu appears
#     only sometimes rather than every cycle.
# Setting both to 0 makes every boot proceed unattended regardless of how the
# previous boot ended.

_step "7 / 9  GRUB: unattended boot (no console operator during automated tests)"

_grub_conf="/etc/default/grub"
if [[ -f "${_grub_conf}" ]]; then
  _grub_changed=0
  _grub_set() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "${_grub_conf}"; then
      if grep -qE "^${key}=${val}\$" "${_grub_conf}"; then
        return 0
      fi
      sed -i -E "s@^${key}=.*@${key}=${val}@" "${_grub_conf}"
    else
      echo "${key}=${val}" >> "${_grub_conf}"
    fi
    _grub_changed=1
  }
  _grub_set "GRUB_TIMEOUT" "0"
  _grub_set "GRUB_RECORDFAIL_TIMEOUT" "0"

  if (( _grub_changed )); then
    if command -v update-grub >/dev/null 2>&1; then
      update-grub >/dev/null
    else
      grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
    fi
    _ok "GRUB_TIMEOUT=0, GRUB_RECORDFAIL_TIMEOUT=0 set in ${_grub_conf}; config regenerated"
  else
    _skip "GRUB_TIMEOUT=0 and GRUB_RECORDFAIL_TIMEOUT=0 already set in ${_grub_conf}"
  fi
else
  _skip "${_grub_conf} not found — not a GRUB-based system, nothing to configure"
fi


# ---------- 8. dev_detect.sh at boot (optional) ------------------------------------
#
# The unit name MUST match what autorun_service_name_for("dev_detect.sh") derives:
#   dev_detect.sh → strip extension → dev_detect → replace _ with - → dev-detect
# This ensures dev_detect.sh's own autorun_setup() sees the service as already
# installed and skips the redundant re-installation on its first manual run.

_step "8 / 9  dev_detect.sh at boot"

# --- Migrate: remove old dut-dev-detect.{timer,service} from previous versions ---
_unit_dir="/etc/systemd/system"
for _old_unit in dut-dev-detect.timer dut-dev-detect.service; do
  if [[ -e "${_unit_dir}/${_old_unit}" ]]; then
    systemctl disable --now "${_old_unit}" 2>/dev/null || true
    rm -f "${_unit_dir}/${_old_unit}"
    _ok "Removed obsolete unit: ${_old_unit}"
  fi
done

if [[ -n "${_dev_detect_script}" ]]; then
  if [[ ! -f "${_dev_detect_script}" ]]; then
    _warn "Script not found: ${_dev_detect_script}"
    echo "         Copy dev_detect.sh to the DUT first, then re-run with --dev-detect-script."
  else
    _dev_detect_script="$(readlink -f "${_dev_detect_script}")"
    _dev_detect_workdir="$(cd "$(dirname "${_dev_detect_script}")" && pwd)"
    _dev_detect_svc="dev-detect"
    _dev_detect_unit="${_unit_dir}/${_dev_detect_svc}.service"
    _dev_detect_log="${_dev_detect_workdir}/logs/systemd_${_dev_detect_svc}.log"

    if systemctl is-enabled --quiet "${_dev_detect_svc}.service" 2>/dev/null; then
      _skip "dev-detect.service already installed and enabled — nothing to do"
    else
      mkdir -p "$(dirname "${_dev_detect_log}")"
      cat > "${_dev_detect_unit}" <<EOF
[Unit]
Description=dev-detect (run once per boot until done)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=${_dev_detect_workdir}
ExecStartPre=/usr/bin/mkdir -p $(dirname "${_dev_detect_log}")
ExecStartPre=/usr/bin/sleep ${_dev_detect_delay}
StandardOutput=append:${_dev_detect_log}
StandardError=append:${_dev_detect_log}
ExecStart=/usr/bin/env bash -lc '${_dev_detect_script}'

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable "${_dev_detect_svc}.service" >/dev/null 2>&1
      _ok "systemd service 'dev-detect.service' registered (boot + ${_dev_detect_delay}s sleep, runs as root)"
      echo "         Script : ${_dev_detect_script}"
    fi
  fi
else
  _skip "dev_detect.sh not configured (not found next to setup_dut.sh)"
  echo "         Place dev_detect.sh in the same folder as setup_dut.sh, or pass"
  echo "         --dev-detect-script with its full path, to register the boot service."
fi


# ---------- 8. Python 3 runtime + report.py renderer --------------------------------

_step "9 / 9  Python 3 runtime + report.py renderer"

if command -v python3 >/dev/null 2>&1; then
  _skip "Python already installed: $(python3 --version 2>&1)"
  _python_ready=1
else
  apt-get update -qq
  apt-get install -y -qq python3
  if command -v python3 >/dev/null 2>&1; then
    _ok "Python installed: $(python3 --version 2>&1)"
    _python_ready=1
  else
    _warn "Python 3 install did not succeed — install manually"
    _python_ready=0
  fi
fi

_report_py="${_script_root}/report.py"
if [[ -f "${_report_py}" ]]; then
  _skip "report.py already present: ${_report_py}"
  _report_ready=1
else
  _url="https://raw.githubusercontent.com/iammaxsu/automatic-testing-architecture/main/src/python/report.py"
  if command -v curl >/dev/null 2>&1 && curl -fsSL "${_url}" -o "${_report_py}"; then
    _ok "report.py downloaded to: ${_report_py}"
    _report_ready=1
  else
    _warn "Could not download report.py"
    echo "         Copy src/python/report.py from the repository manually."
    _report_ready=0
  fi
fi


# ---------- Summary -------------------------------------------------------------------

echo
echo "========================================================"
echo "  DUT Setup Complete"
echo "========================================================"
echo "  Test user         : ${_test_user}"
echo "  SSH (TCP 22)      : installed + running"
if [[ -n "${_pi_key}" ]]; then
  echo "  Pi SSH key        : authorized (${_auth_file}, source: ${_pi_key_source})"
elif (( ${_existing_keys:-0} > 0 )); then
  echo "  Pi SSH key        : already authorized (${_existing_keys} key(s) — left as-is)"
else
  echo "  Pi SSH key        : NOT authorized (pass --pi-key to enable passwordless SSH)"
fi
echo "  NOPASSWD sudo     : shutdown/reboot/poweroff/restore for ${_test_user}"
echo "  Restore helper    : ${_restore_helper}  (auto-called by Pi on test complete)"
echo "  Power management  : no sleep/suspend/hibernate; HandlePowerKey=poweroff"
echo "  logind drop-in    : ${TEST_ENV_LOGIND_DROPIN}"
echo "  Unattended-upgrades auto-reboot : disabled (if installed)"
echo "  GRUB unattended boot : timeout=0, recordfail-timeout=0 (if GRUB-based)"
if [[ -n "${_dev_detect_script}" && -f "${_dev_detect_script}" ]]; then
  echo "  dev-detect service: dev-detect.service (boot + ${_dev_detect_delay}s sleep, as root)"
else
  echo "  dev-detect service: dev-detect.service not configured"
fi
if [[ "${_python_ready:-0}" -eq 1 ]]; then
  echo "  Python runtime    : available"
else
  echo "  Python runtime    : install manually then re-run this script"
fi
if [[ "${_report_ready:-0}" -eq 1 ]]; then
  echo "  report.py         : present (HTML reports can be rendered locally)"
else
  echo "  report.py         : not available — copy from src/python/report.py manually"
fi
echo
echo "  >>> Verify from the Pi: ssh ${_test_user}@<this-host> 'uname -s' should print 'Linux' <<<"
echo "========================================================"
