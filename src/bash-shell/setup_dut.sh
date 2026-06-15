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
#   7. (Optional) Registers a systemd oneshot+timer to run dev_detect.sh at boot
#   8. Ensures Python 3 is present and downloads report.py for HTML rendering
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
# Options:
#   --test-user USERNAME       Account the Pi controller logs in as
#                               (default: $SUDO_USER, or current user if not under sudo)
#   --pi-key "ssh-ed25519 AAAA...key... pi@raspberrypi"
#                               Public key of the Pi controller (contents of
#                               ~/.ssh/id_ed25519.pub on the Pi). Installed into
#                               --test-user's authorized_keys (idempotent).
#   --pi-key-file PATH          Same as --pi-key but read the key from a file.
#   --dev-detect-script PATH    Path to dev_detect.sh to register as a boot-time
#                               systemd service. Default: auto-detect a sibling
#                               dev_detect.sh next to this script (FWK034).
#   --dev-detect-delay SEC      Delay after boot before running dev_detect.sh
#                               (default: 30).
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

_script_ver="00.00.01"

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

_test_user="${SUDO_USER:-${USER}}"
_pi_key=""
_dev_detect_script=""
_dev_detect_delay=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-user)         _test_user="$2"; shift 2 ;;
    --pi-key)            _pi_key="$2"; shift 2 ;;
    --pi-key-file)       _pi_key="$(cat "$2")"; shift 2 ;;
    --dev-detect-script) _dev_detect_script="$2"; shift 2 ;;
    --dev-detect-delay)  _dev_detect_delay="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,55p' "${_entry}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# ---------- Auto-detect sibling dev_detect.sh (FWK034) --------------------------
if [[ -z "${_dev_detect_script}" ]]; then
  _sibling="${_script_root}/dev_detect.sh"
  if [[ -f "${_sibling}" ]]; then
    _dev_detect_script="${_sibling}"
    echo "         Auto-detected dev_detect.sh : ${_sibling}"
  fi
fi

_target_home="$(getent passwd "${_test_user}" | cut -d: -f6)"
if [[ -z "${_target_home}" ]]; then
  echo "ERROR: user '${_test_user}' not found (pass --test-user)" >&2
  exit 1
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

if [[ -n "${_pi_key}" ]]; then
  mkdir -p "${_ssh_dir}"
  chmod 700 "${_ssh_dir}"
  touch "${_auth_file}"
  chmod 600 "${_auth_file}"

  if grep -qF "${_pi_key}" "${_auth_file}" 2>/dev/null; then
    _skip "Pi SSH public key already present in ${_auth_file}"
  else
    echo "${_pi_key}" >> "${_auth_file}"
    _ok "Pi SSH public key appended to ${_auth_file}"
  fi

  chown -R "${_test_user}:${_test_user}" "${_ssh_dir}"
  _ok "ownership/permissions fixed: ${_ssh_dir} (700), authorized_keys (600)"
  echo "         Test from the Pi: ssh ${_test_user}@<this-host>"
else
  _skip "SSH key install skipped (no --pi-key / --pi-key-file supplied)"
  echo "         Obtain the key on the Pi with: cat ~/.ssh/id_ed25519.pub"
  echo "         then re-run: sudo ./setup_dut.sh --test-user ${_test_user} --pi-key \"<key>\""
fi


# ---------- 4. NOPASSWD sudo for shutdown / reboot --------------------------------
#
# shutdown.py's SSH shutdown method and reboot.py both run "sudo shutdown -h now"
# / "sudo reboot" over a non-interactive SSH session (config._OS_SHUTDOWN_CMD /
# _OS_REBOOT_CMD for dut_os=linux). Without NOPASSWD these hang waiting for a
# password that BatchMode will never supply.

_step "4 / 8  NOPASSWD sudo (shutdown / reboot / poweroff)"

_sudoers_file="/etc/sudoers.d/99-automatic-testing-${_test_user}"
_sudoers_line="${_test_user} ALL=(ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /sbin/poweroff, /usr/sbin/shutdown, /usr/sbin/reboot, /usr/sbin/poweroff"

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


# ---------- 5. Power management: disable sleep / suspend / hibernate -------------

_step "5 / 8  Power management (no sleep / suspend / hibernate)"

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
_ok "systemd sleep/suspend/hibernate/hybrid-sleep targets masked"

_logind_conf="/etc/systemd/logind.conf"
_logind_changed=0
declare -A _logind_settings=(
  [HandleLidSwitch]=ignore
  [HandleLidSwitchExternalPower]=ignore
  [HandleLidSwitchDocked]=ignore
  [HandleSuspendKey]=ignore
  [HandleHibernateKey]=ignore
  [IdleAction]=ignore
)
for _key in "${!_logind_settings[@]}"; do
  _val="${_logind_settings[$_key]}"
  if grep -qE "^${_key}=" "${_logind_conf}" 2>/dev/null; then
    if ! grep -qE "^${_key}=${_val}$" "${_logind_conf}"; then
      sed -i "s/^${_key}=.*/${_key}=${_val}/" "${_logind_conf}"
      _logind_changed=1
    fi
  else
    echo "${_key}=${_val}" >> "${_logind_conf}"
    _logind_changed=1
  fi
done
if [[ "${_logind_changed}" -eq 1 ]]; then
  systemctl restart systemd-logind >/dev/null 2>&1 || true
  _ok "logind.conf updated (lid/idle actions ignored); systemd-logind restarted"
else
  _skip "logind.conf already configured"
fi


# ---------- 6. Disable unattended-upgrades automatic reboot -----------------------

_step "6 / 8  Unattended-upgrades automatic reboot"

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


# ---------- 7. dev_detect.sh at boot (optional) ------------------------------------

_step "7 / 8  dev_detect.sh at boot"

if [[ -n "${_dev_detect_script}" ]]; then
  if [[ ! -f "${_dev_detect_script}" ]]; then
    _warn "Script not found: ${_dev_detect_script}"
    echo "         Copy dev_detect.sh to the DUT first, then re-run with --dev-detect-script."
  else
    _dev_detect_script="$(readlink -f "${_dev_detect_script}")"
    _unit_dir="/etc/systemd/system"

    cat > "${_unit_dir}/dut-dev-detect.service" <<EOF
[Unit]
Description=Run dev_detect.sh for hardware baseline verification (DET012)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash ${_dev_detect_script}
WorkingDirectory=$(dirname "${_dev_detect_script}")
EOF

    cat > "${_unit_dir}/dut-dev-detect.timer" <<EOF
[Unit]
Description=Run dut-dev-detect.service ${_dev_detect_delay}s after boot

[Timer]
OnBootSec=${_dev_detect_delay}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now dut-dev-detect.timer >/dev/null
    _ok "systemd timer 'dut-dev-detect.timer' registered (boot + ${_dev_detect_delay}s, runs as root)"
    echo "         Script : ${_dev_detect_script}"
  fi
else
  _skip "dev_detect.sh not configured (not found next to setup_dut.sh)"
  echo "         Place dev_detect.sh in the same folder as setup_dut.sh, or pass"
  echo "         --dev-detect-script with its full path, to register the boot timer."
fi


# ---------- 8. Python 3 runtime + report.py renderer --------------------------------

_step "8 / 8  Python 3 runtime + report.py renderer"

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
echo "  SSH (TCP 22)      : installed + running"
if [[ -n "${_pi_key}" ]]; then
  echo "  Pi SSH key        : installed (${_auth_file})"
else
  echo "  Pi SSH key        : not installed (pass --pi-key to enable passwordless SSH)"
fi
echo "  NOPASSWD sudo     : shutdown/reboot/poweroff for ${_test_user}"
echo "  Power management  : no sleep / suspend / hibernate"
echo "  Unattended-upgrades auto-reboot : disabled (if installed)"
if [[ -n "${_dev_detect_script}" && -f "${_dev_detect_script}" ]]; then
  echo "  systemd timer     : dut-dev-detect.timer (boot + ${_dev_detect_delay}s, as root)"
else
  echo "  systemd timer     : dut-dev-detect.timer not configured"
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
