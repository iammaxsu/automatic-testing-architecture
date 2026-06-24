#!/usr/bin/env bash
# ---------- --help / -h (DET013): answer before requiring root ----------
# Checked first so a user can see usage without sudo/root.
for _arg in "$@"; do
  case "${_arg}" in
    --help|-h)
      cat <<'USAGE'
Usage: dev_detect.sh [N] [options]

  N                     Number of detection passes to run across reboots
                        (standalone mode only; default 1).

Run modes:
  (no flag)             Standalone mode (default). The script owns its own
                        persistent loop: installs a systemd autorun service
                        and reboots/powers off itself between passes until
                        N passes have run.
  --snapshot-only       Run exactly ONE detection pass and exit. Does NOT
                        install autorun and does NOT reboot/poweroff.
                        Intended for use under an external orchestrator
                        (e.g. power_cycle.py) that already owns the
                        power-cycle loop.

Other options:
  --power-cycle         In standalone mode, use poweroff instead of reboot
                        between passes (default: reboot).
  --vpu-check           Enable the optional VPU (PCIe device 1ffc) check.
  --vpu-vid VID         VPU vendor:device ID to match (default: 1ffc).
  --vpu-count N         Expected VPU device count (default: 18).
  --vpu-speed SPEED     Expected PCIe link speed, e.g. 8GT/s (default: 8GT/s).
  --vpu-width WIDTH     Expected PCIe link width, e.g. x2 (default: x2).
  --help, -h            Show this help and exit.

Exit codes (every pass, both modes):
  0  Pass   - output matches an existing golden reference
  1  Fail   - output deviates from an existing golden reference
  2  Error  - detection could not run
  3  INIT   - no golden existed; one was just created (not a verified pass)
  64 Usage  - unrecognized command-line argument (no pass run)

Each pass also writes a JSON sidecar next to its .log file; see
docs/dev_detect.md for the schema.
USAGE
      exit 0
      ;;
  esac
done

# ---------- Self-elevate to root (FWK025) ----------
# This test reads SMBIOS/USB descriptors that require root.
# If invoked as a non-root user, re-execute under sudo, preserving
# environment (-E) and arguments ("$@"). Output ownership is restored
# to the original user via fix_log_permissions (function.sh) on EXIT.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

set -Eeuo pipefail

export _dev_detect_version
: "${_dev_detect_version:="00.00.05"}"
#: "${_dev_detect_requires_config_api_version:=00.00.01}"
#: "${_dev_detect_requires_function_api_version:=00.00.01}"

# ---------- Locate & source companions (REQUIRED) ----------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"     # The script with full path, e.g. /home/adlink/Downloads/test.sh.
_entry_dir="$(cd "$(dirname "${_entry}")" && pwd)"      # The directory of the script, e.g. /home/adlink/Downloads.

find_and_source() {
  local _name="$1"
  local search_dirs=(     # Directories to search for the companion scripts
    "${_entry_dir}"
    "/home/${USER}/Downloads"
  )

  for _dir in "${search_dirs[@]}"; do
    if [[ -f "${_dir}/${_name}" ]]; then
      . "${_dir}/${_name}"
      return 0
    fi
  done

  echo "FATAL: cannot find ${_name} in any of the search directories." >&2
  printf " - %s\n" "${search_dirs[@]}" >&2
  exit 1
}

find_and_source "config.sh"
find_and_source "function.sh"

# ---------- Cleanup on exit ----------
# dev_detect reboots the machine multiple times. Each run's EXIT trap fires
# before the reboot, so logs get readable by the login user even between
# reboots or if the final run (generate_dev_detect_report) never completes.
#
# _log_dir is not assigned until log_dir() runs further below, so any exit
# before that point (e.g. check_api_versions's exit 63, or a CLI usage
# error) used to hit fix_log_permissions with $1 expanding to "" and its
# own "${1:-${_log_dir}}" fallback then reading a still-unbound _log_dir
# under `set -u`, which replaced the real exit code with 1. Bind it to ""
# up front so every exit path -- not just the ones that happened to be
# exercised before -- reports its real exit code.
: "${_log_dir:=}"
trap 'fix_log_permissions "${_log_dir:-}" deep' EXIT

# ---- API version check ----
: "${_requires_config_api:=00.00.01}"
: "${_requires_function_api:=00.00.02}"
check_api_versions "dev_detect.sh" "${_requires_config_api}" "${_requires_function_api}"

#_function_require_versions "${_dev_detect_test_name}" "${_dev_detect_requires_config_api_version}" "${_dev_detect_requires_function_api_version}" "${_dev_detect_api_version}"


# ---------- Optional Module: VPU Check (Device 1ffc) ----------
# Enable via CLI flag: --vpu-check
# Optional overrides:
#   --vpu-vid 1ffc          (default 1ffc)
#   --vpu-count 18          (default 18)
#   --vpu-speed 8GT/s       (default 8GT/s)
#   --vpu-width x2          (default x2)
#
# This module is designed to be modular: if not enabled, dev_detect behaves as before.
_vpu_enable=0
_vpu_vid="1ffc"
_vpu_expect_count=18
_vpu_expect_speed="8GT/s"
_vpu_expect_width="x2"

_reset_mode="reboot"   # reboot | power-cycle  (pass --power-cycle to switch)

# DET013: snapshot mode hands the persistent loop over to an external
# orchestrator (power_cycle.py). One pass, no autorun, no reboot/poweroff.
_snapshot_only=0

_parse_vpu_flags_from_rem_args() {
  # Parse from REM_ARGS (provided by parse_common_cli in function.sh).
  # We do NOT mutate REM_ARGS because autorun_install_self_if_needed reuses it.
  #
  # DET013 / contract-alignment-plan Layer 1: any token here that is not one
  # of the flags below (a typo, a stray positional, an unsupported option)
  # used to be silently dropped and the script ran a normal pass anyway --
  # the same class of bug fixed on the PowerShell side. Now it is a hard
  # usage error, matching dev_detect.ps1's exit 64 (EX_USAGE).
  local i=0
  local -a _unrecognized=()
  while [[ $i -lt ${#REM_ARGS[@]} ]]; do
    case "${REM_ARGS[$i]}" in
      --vpu-check)      _vpu_enable=1 ;;
      --vpu-vid)        ((i+=1)); _vpu_vid="${REM_ARGS[$i]:-$_vpu_vid}" ;;
      --vpu-count)      ((i+=1)); _vpu_expect_count="${REM_ARGS[$i]:-$_vpu_expect_count}" ;;
      --vpu-speed)      ((i+=1)); _vpu_expect_speed="${REM_ARGS[$i]:-$_vpu_expect_speed}" ;;
      --vpu-width)      ((i+=1)); _vpu_expect_width="${REM_ARGS[$i]:-$_vpu_expect_width}" ;;
      --power-cycle)    _reset_mode="power-cycle" ;;
      --snapshot-only)  _snapshot_only=1 ;;
      *)                _unrecognized+=("${REM_ARGS[$i]}") ;;
    esac
    ((i+=1))
  done

  if [[ ${#_unrecognized[@]} -gt 0 ]]; then
    echo "dev_detect.sh: unrecognized argument(s): ${_unrecognized[*]}" >&2
    echo "Run 'dev_detect.sh --help' for usage." >&2
    exit 64   # EX_USAGE; deliberately NOT a DET013 verdict (0/1/2/3)
  fi
}

_vpu_need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

vpu_check_run() {
  # Args: $1 output_log_path
  local out="$1"
  local pass=0 fail=0 count_ok=0
  local -a bdfs=()

  {
    echo "# === VPU Check (VID ${_vpu_vid}) ==="
    echo "Expect: count=${_vpu_expect_count}, Speed=${_vpu_expect_speed}, Width=${_vpu_expect_width}"
    echo "Host: $(hostname)  Kernel: $(uname -r)"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
  } >>"$out"

  if ! _vpu_need_cmd lspci || ! _vpu_need_cmd awk || ! _vpu_need_cmd sed || ! _vpu_need_cmd grep; then
    echo "[FAIL] required tools missing (lspci/awk/sed/grep)" >>"$out"
    return 1
  fi

  while IFS= read -r bdf; do
    [[ -n "$bdf" ]] && bdfs+=("$bdf")
  done < <(sudo lspci | grep -i "Device ${_vpu_vid}" | awk '{print $1}' || true)

  local count="${#bdfs[@]}"
  {
    echo "Found count: ${count} (expected ${_vpu_expect_count})"
    if [[ "$count" -eq "${_vpu_expect_count}" ]]; then
      echo "[PASS] Count == ${_vpu_expect_count}"
      count_ok=1
    else
      echo "[FAIL] Count != ${_vpu_expect_count}"
    fi
    echo
    printf "%-10s | %-8s | %-6s | %-6s | %s\n" "BDF" "Speed" "Width" "Result" "Note"
    printf -- "-------------------------------------------------------------\n"
  } >>"$out"

  for bdf in "${bdfs[@]}"; do
    local lnksta speed width result note
    lnksta="$(sudo lspci -s "$bdf" -vvv 2>/dev/null | grep -i -m1 'LnkSta:' || true)"
    speed="$(sed -n 's/.*Speed[[:space:]]\+\([^[:space:]]\+\).*/\1/p' <<<"$lnksta")"
    width="$(sed -n 's/.*Width[[:space:]]\+\([^[:space:]]\+\).*/\1/p' <<<"$lnksta")"

    result="PASS"; note="ok"
    if [[ -z "$lnksta" ]]; then
      result="FAIL"; note="no LnkSta"
    else
      if [[ "$speed" != "${_vpu_expect_speed}" ]]; then
        result="FAIL"; note="speed=${speed:-?}"
      fi
      if [[ "$width" != "${_vpu_expect_width}" ]]; then
        result="FAIL"
        if [[ "$note" == "ok" ]]; then note="width=${width:-?}"
        else note="${note} width=${width:-?}"
        fi
      fi
    fi

    if [[ "$result" == "PASS" ]]; then
      ((++pass))
    else
      ((++fail))
    fi

    printf "%-10s | %-8s | %-6s | %-6s | %s\n" \
      "$bdf" "${speed:-?}" "${width:-?}" "$result" "$note" >>"$out"
  done

  {
    echo
    echo "Summary: device-pass=${pass}, device-fail=${fail}"
  } >>"$out"

  if [[ "$count_ok" -eq 1 && "$fail" -eq 0 ]]; then
    echo "[OVERALL PASS]" >>"$out"
    return 0
  else
    echo "[OVERALL FAIL]" >>"$out"
    return 1
  fi
}

# ---------- Device detection helpers (local to dev_detect.sh) ----------
_emit_section() {
	printf '\n# === %s ===\n' "$1"
}

detect_cpu() {
  _emit_section "CPU"

	# ===== Basic Information =====
  if command -v lscpu >/dev/null 2>&1; then
    local _model _cores _sockets _tpc _vendor
    _model="$(lscpu | awk -F': +' '/Model name/{print $2; exit}')"
    _cores="$(lscpu | awk -F': +' '/^CPU\(s\)/{print $2; exit}')"
    _sockets="$(lscpu | awk -F': +' '/Socket\(s\)/{print $2; exit}')"
		_tpc="$(lscpu | awk -F': *' '/^Thread\(s\) per core/{print $2; exit}')"
    _vendor="$(awk -F': *' '/^Vendor ID/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
		printf 'Test Case: Name of CPU <Test on Linux OS>\n'
    printf 'Model: %s\n\n' "${_model:-unknown}"
		printf 'Test Case: Processors Core # of CPU <Test on Linux OS>\n'
    printf 'Cores: %s\n\n' "${_cores:-unknown}"
    printf 'Sockets: %s\n' "${_sockets:-unknown}"
	else
    echo "lscpu: Not Found"
  fi

  # ===== Feature State: Enabled/Disabled/Not Support, Unknown if unavailable) =====

  ## tools
  _has_flag() {
		grep -m1 -wo "$1" /proc/cpuinfo >/dev/null 2>&1
	}

  _readf() {
		[[ -r "$1" ]] && tr -d '\n' < "$1" || echo ""
	}

  _print_feature() {
    ### $1 Name, $2 Support (0/1), $3 State 1/0/Unknown
    local _name="$1" _sup="$2" _en="$3" _s
    if [[ "${_sup}" -eq 0 ]]; then _s="Not Support"
    else
      case "${_en}" in
				1) _s="Enabled";;
				0) _s="Disabled";;
				*) _s="Unknown";; 
			esac
    fi
    printf '%-12s : %s\n' "${_name}" "${_s}"
  }

  ## Intel® Hyper-Threading (HT)/AMD Simultaneous Multithreading (SMT)
  local _ht_sup=0 _ht_en="Unknown"
  _has_flag ht && _ht_sup=1
  if [[ -r /sys/devices/system/cpu/smt/active ]]; then
    case "$(_readf /sys/devices/system/cpu/smt/active)" in
			1) _ht_en=1;;
			0) _ht_en=0;;
		esac
  else
    ### 後備：Threads per core >1 視為 enabled
    local _tpc_val; _tpc_val="$(lscpu | awk -F': *' '/^Thread\(s\) per core/{print $2; exit}')"
    [[ -n "${_tpc_val}" && "${_tpc_val}" -gt 1 ]] && _ht_en=1 || _ht_en=0
  fi

  _print_feature "HT/SMT" "${_ht_sup}" "${_ht_en}"

  ## Intel® Enhanced Intel SpeedStep® Technology
  local _eist_sup=0 _eist_en="Unknown"
  _has_flag est && _eist_sup=1
  if [[ -d /sys/devices/system/cpu/cpufreq/policy0 ]]; then
    _eist_en=1
  else
    [[ "${_eist_sup}" -eq 1 ]] && _eist_en=0
  fi

  _print_feature "EIST" "${_eist_sup}" "${_eist_en}"

  ## Intel® Turbo Boost Technology
  local _turbo_sup=0 _turbo_en="unknown"
  local _vendor_id; _vendor_id="$(awk -F': *' '/^Vendor ID/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [[ "${_vendor_id}" == "GenuineIntel" ]] && _turbo_sup=1
  if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    case "$(_readf /sys/devices/system/cpu/intel_pstate/no_turbo)" in
			0) _turbo_en=1;;
			1) _turbo_en=0;;
		esac
  elif [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
    case "$(_readf /sys/devices/system/cpu/cpufreq/boost)" in
			1) _turbo_en=1;;
			0) _turbo_en=0;;
		esac
  fi

  _print_feature "TurboBoost" "${_turbo_sup}" "${_turbo_en}"

  ## Intel® Virtualization Technology (VT-x)
  local _vtx_sup=0 _vtx_en="Unknown"
  _has_flag vmx && _vtx_sup=1
  if [[ "${_vtx_sup}" -eq 1 ]]; then
    if [[ -e /dev/kvm ]] && lsmod 2>/dev/null | grep -q '^kvm_intel'; then
      _vtx_en=1
    else
      _vtx_en=0
    fi
  fi

  _print_feature "VT-x" "${_vtx_sup}" "${_vtx_en}"

  ## Intel® Virtualization Technology (Intel® VT) for Directed I/O (Intel® VT-d/IOMMU)
  local _vtd_sup=0 _vtd_en="Unknown"
  if [[ "${_vendor_id}" == "GenuineIntel" ]] && \
     { grep -qiE 'DMAR|IOMMU' /proc/iomem 2>/dev/null || dmesg 2>/dev/null | grep -qiE 'DMAR|IOMMU'; }; then
    _vtd_sup=1
  fi
  if [[ "${_vtd_sup}" -eq 1 ]]; then
    if [[ -d /sys/kernel/iommu_groups ]] && [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
      _vtd_en=1
    else
      _vtd_en=0
    fi
  fi

  _print_feature "VT-d" "${_vtd_sup}" "${_vtd_en}"
}

detect_ram() {
  _emit_section "RAM"

  # 總量（參考）
  if command -v free >/dev/null 2>&1; then
    printf 'Total: %s\n' "$(free -h | awk '/^Mem:/{print $2}')"
  fi

  if ! command -v dmidecode >/dev/null 2>&1; then
    echo "dmidecode: not found; cannot list slots/speed/voltage"
    return 0
  fi

  # 逐槽列出（含空槽）；以 "Handle ..., DMI type 17" 為區塊起點，避免 mawk 對 RS="" 的相容性問題
  LANG=C dmidecode -t memory 2>/dev/null | awk '
    BEGIN{
      printed=0; total=0; pop=0; inblk=0;
      loc=bank=type=size=spd=cfgspd=vcfg=vmin=vmax=mfg=pn="";
    }

    # 每遇到一條 Handle ... DMI type 17 視為新插槽起點；先收尾舊區塊
    /^Handle [^,]+, DMI type 17/ {
      if (inblk) {
        status = "Populated"
        if (size=="" || size ~ /No Module Installed/ || size ~ /Not Installed/ || size ~ /^0[ \t]*[MG]B$/) status="Empty"
        final_spd = (cfgspd!="" ? cfgspd : (spd!="" ? spd : "?"))
        if      (vcfg!="")                           volt=vcfg
        else if (vmin!="" && vmax!="" && vmin!=vmax) volt=vmin " ~ " vmax
        else if (vmin!="" && vmax=="")               volt=vmin
        else if (vmin=="" && vmax!="")               volt=vmax
        else                                         volt="?"

        if (loc==""||loc=="Unknown") loc="?"
        if (bank==""||bank=="Unknown") bank="?"
        if (type==""||type=="Unknown") type="?"
        if (size==""||size=="Unknown") size="?"
        if (final_spd==""||final_spd=="Unknown") final_spd="?"
        if (volt==""||volt=="Unknown") volt="?"
        if (pn==""||pn=="Unknown") pn="?"
        if (mfg==""||mfg=="Unknown") mfg="?"

				if (!printed) {
					printf "%-28s %-8s %-8s %-12s %-14s %-10s %-22s %-24s [%s]\n",
								"Locator","Bank","Type","Size","Speed","Voltage","PartNumber","Manufacturer","Status"
					printed=1
				}
				pn_out = (pn  != "" && pn  != "Unknown") ? pn  : "?"
				mf_out = (mfg != "" && mfg != "Unknown") ? mfg : "?"
				printf "%-28s %-8s %-8s %-12s %-14s %-10s %-22s %-24s [%s]\n",
							loc, bank, type, size, final_spd, volt, pn_out, mf_out, status

        total++; if (status=="Populated") pop++;
      }
      inblk=1
      loc=bank=type=size=spd=cfgspd=vcfg=vmin=vmax=mfg=pn=""
      next
    }

    # 區塊內擷取欄位
    inblk {
      line=$0; sub(/\r$/,"",line)
      if (line ~ /^[ \t]*Locator:/ && loc=="")                         { sub(/^[ \t]*Locator:[ \t]*/,"",line);               loc=line }
      else if (line ~ /^[ \t]*Bank Locator:/ && bank=="")              { sub(/^[ \t]*Bank Locator:[ \t]*/,"",line);          bank=line }
      else if (line ~ /^[ \t]*Type:/ && type=="")                      { sub(/^[ \t]*Type:[ \t]*/,"",line);                  type=line }
      else if (line ~ /^[ \t]*Size:/ && size=="")                      { sub(/^[ \t]*Size:[ \t]*/,"",line);                  size=line }
      else if (line ~ /^[ \t]*Configured Memory Speed:/ && cfgspd=="") { sub(/^[ \t]*Configured Memory Speed:[ \t]*/,"",line); cfgspd=line }
      else if (line ~ /^[ \t]*Configured Clock Speed:/ && cfgspd=="")  { sub(/^[ \t]*Configured Clock Speed:[ \t]*/,"",line);  cfgspd=line }
      else if (line ~ /^[ \t]*Speed:/ && spd=="")                      { sub(/^[ \t]*Speed:[ \t]*/,"",line);                 spd=line }
      else if (line ~ /^[ \t]*Configured Voltage:/ && vcfg=="")        { sub(/^[ \t]*Configured Voltage:[ \t]*/,"",line);    vcfg=line }
      else if (line ~ /^[ \t]*Minimum Voltage:/ && vmin=="")           { sub(/^[ \t]*Minimum Voltage:[ \t]*/,"",line);       vmin=line }
      else if (line ~ /^[ \t]*Maximum Voltage:/ && vmax=="")           { sub(/^[ \t]*Maximum Voltage:[ \t]*/,"",line);       vmax=line }
      else if (line ~ /^[ \t]*Manufacturer:/ && mfg=="")               { sub(/^[ \t]*Manufacturer:[ \t]*/,"",line);          mfg=line }
      else if (line ~ /^[ \t]*Part Number:/ && pn=="")                 { sub(/^[ \t]*Part Number:[ \t]*/,"",line);           pn=line }
      next
    }

    # 檔尾：最後一塊（沒有遇到下一個 Handle）
    END {
      if (inblk) {
        status = "Populated"
        if (size=="" || size ~ /No Module Installed/ || size ~ /Not Installed/ || size ~ /^0[ \t]*[MG]B$/) status="Empty"
        final_spd = (cfgspd!="" ? cfgspd : (spd!="" ? spd : "?"))
        if      (vcfg!="")                           volt=vcfg
        else if (vmin!="" && vmax!="" && vmin!=vmax) volt=vmin " ~ " vmax
        else if (vmin!="" && vmax=="")               volt=vmin
        else if (vmin=="" && vmax!="")               volt=vmax
        else                                         volt="?"
        if (loc==""||loc=="Unknown") loc="?"
        if (bank==""||bank=="Unknown") bank="?"
        if (type==""||type=="Unknown") type="?"
        if (size==""||size=="Unknown") size="?"
        if (final_spd==""||final_spd=="Unknown") final_spd="?"
        if (volt==""||volt=="Unknown") volt="?"
        if (pn==""||pn=="Unknown") pn="?"
        if (mfg==""||mfg=="Unknown") mfg="?"
        if (!printed) {
          printf "%-28s %-8s %-8s %-12s %-14s %-10s %s\n",
                 "Locator","Bank","Type","Size","Speed","Voltage","PartNumber(Manufacturer) [Status]"
          printed=1
        }
        pnmfg = pn " (" mfg ")"
        printf "%-28s %-8s %-8s %-12s %-14s %-10s %s  [%s]\n",
               loc, bank, type, size, final_spd, volt, pnmfg, status
        total++; if (status=="Populated") pop++;
      }
      if (printed) printf "Slots: %d  Populated: %d  Empty: %d\n", total, pop, total-pop
      else print "No Memory Device entries found in DMI."
    }
  '
}

#detect_usb() {
#  _emit_section "USB"
#  if command -v lsusb >/dev/null 2>&1; then
#		while IFS= read -r line; do
#			bus="$(echo "$line" | awk '{print $2}')"
#			dev="$(echo "$line" | awk '{print $4}' | sed 's/://')"
#			node="$(printf '/sys/bus/usb/devices/%s-%s' "$bus" "$dev")"
#			if [[ ! -e "${node}" ]]; then
#				node="$(grep -l "^$bus$" /sys/bus/usb/devices/*/busnum 2>/dev/null \
#					| xargs -r -I{} dirname {} \
#					| while read -r p; do
#							[[ "$(cat "$p/devnum" 2>/dev/null)" == "$dev" ]] && echo "$p"
#						done
#					head -n1)"
#			fi
#
#			printf '%s\n' "$line"
#			[[ -n "$node" ]] && usb_summarize_node "$node"
#		done < <(LANG=C lsusb)
#  else
#    echo "lsusb: not found"
#  fi
#}

detect_usb() {
  _emit_section "USB"
  usbutils_install >/dev/null 2>&1 || true

  if ! command -v lsusb >/dev/null 2>&1; then
    echo "lsusb: not found"
    return 0
  fi

  # 先列 Hub 與各埠狀態（含 root hub）
  echo "## Hubs & Ports"
  # 表頭：Bus Dev ID Desc
  printf "%-6s %-6s %-9s %s\n" "Bus" "Dev" "ID" "Hub Description"
  while IFS= read -r line; do
    # 範例：Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
    bus="$(echo "$line" | awk '{print $2}')"
    dev="$(echo "$line" | awk '{print $4}' | sed 's/://')"
    vidpid="$(echo "$line" | awk '{print $6}')"
    desc="$(echo "$line" | cut -d" " -f7-)"

    # 判斷是否為 Hub（root hub 或外接 hub）
    is_hub=0
    case "$desc" in
      *"root hub"*) is_hub=1 ;;
      *) # 用 lsusb -v 的 bDeviceClass 判定
         if lsusb -s "${bus}:${dev}" -v 2>/dev/null | awk '/bDeviceClass/ {exit($2==9?0:1)}'; then
           is_hub=1
         fi
         ;;
    esac

    if [[ "$is_hub" -eq 1 ]]; then
      printf "%-6s %-6s %-9s %s\n" "$bus" "$dev" "$vidpid" "$desc"
      usb_list_hub_ports "$bus" "$dev" || true
    fi
  done < <(LANG=C lsusb)

  echo
  echo "## Connected USB devices"
  printf "%-6s %-6s %-9s %s\n" "Bus" "Dev" "ID" "Description / Link"

  # 再列出非 hub 的實際裝置，並顯示連線速率/世代
  while IFS= read -r line; do
    bus="$(echo "$line" | awk '{print $2}')"
    dev="$(echo "$line" | awk '{print $4}' | sed 's/://')"
    vidpid="$(echo "$line" | awk '{print $6}')"
    desc="$(echo "$line" | cut -d" " -f7-)"

    # 跳過 hub（避免重複），只列終端裝置
    if lsusb -s "${bus}:${dev}" -v 2>/dev/null | awk '/bDeviceClass/ {exit($2==9?0:1)}'; then
      continue
    fi

    node="$(usb_sysnode_from_bus_dev "$bus" "$dev" || true)"
    printf "%-6s %-6s %-9s %s\n" "$bus" "$dev" "$vidpid" "$desc"
    if [[ -n "$node" ]]; then
      usb_summarize_node "$node"
    else
      echo "Current=?  bcdUSB=?"
    fi
  done < <(LANG=C lsusb)
}

#detect_pcie_eth() {
#  _emit_section "PCIe Ethernet"
#  if ! command -v lspci >/dev/null 2>&1; then
#		echo "lspci: not found"
#		return
#	fi
#
#  # 每次都印表頭，確保 snapshot 與 golden 一致
#  printf "%-12s  %-42s  %-9s  %-7s  %-9s  %-7s  %-10s\n" \
#    "BDF" "Device(Name[IDs])" "LnkCapSpd" "CapW" "LnkStaSpd" "StaW" "ASPM"
#
#  while IFS= read -r line; do
#    bdf="${line%% *}"                 # 0000:3b:00.0
#    rest="${line#* }"                 # Ethernet controller: Intel ... [8086:1572]
#    name="${rest%%\[*}"               # Ethernet controller: Intel ...
#    ids="$(echo "$rest" | sed -n 's/.*\[\([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\)\].*/\1/p')"
#
#    # 抓 -vv 三行：LnkCap / LnkSta / LnkCtl（ASPM）
#    dump="$(LANG=C lspci -vv -s "$bdf")"
#
#    cap="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkCap:' \
#          | sed -n 's/.*Speed \([^,]*\), Width x\([0-9]\+\).*/\1 \2/p')"
#    sta="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkSta:' \
#          | sed -n 's/.*Speed \([^,]*\), Width x\([0-9]\+\).*/\1 \2/p')"
#    aspm="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkCtl:' \
#          | sed -n 's/.*ASPM \([A-Za-z0-9 ][A-Za-z0-9 ]*\).*/\1/p')"
#
#    # 拆值並給預設 "?"
#    read -r cap_speed cap_width <<<"${cap:-"? ?"}"
#    read -r sta_speed sta_width <<<"${sta:-"? ?"}"
#    aspm="${aspm:-?}"
#
#    devlabel="$(printf '%s [%s]' "$(echo "$name" | sed 's/[[:space:]]*$//')" "${ids:-????:????}")"
#
#    printf "%-12s  %-42s  %-9s  x%-6s  %-9s  x%-6s  %-10s\n" \
#      "$bdf" "$devlabel" "$cap_speed" "$cap_width" "$sta_speed" "$sta_width" "$aspm"
#
#  done < <(LANG=C lspci -Dnn | grep -i 'Ethernet controller')
#}

detect_pcie_ethernet() {
  _emit_section "PCIe Ethernet"
  command -v lspci >/dev/null 2>&1 || { echo "lspci: not found"; return 0; }

  printf "%-14s %-40s %-10s %-6s %-10s %-6s %-s\n" \
    "BDF" "Device(Name[IDs])" "LnkCapSpd" "CapW" "LnkStaSpd" "StaW" "ASPM"

  while IFS= read -r line; do
    # 例：0000:3b:00.0 Ethernet controller [0200]: Intel Corporation I225-V [8086:15f3] ...
    bdf="$(printf '%s\n' "$line" | awk '{print $1}')"
    name_ids="$(printf '%s\n' "$line" | sed -n 's/^[^]]*]:[[:space:]]*\(.*\)$/\1/p')"
    link="$(pcie_link_info "$bdf")"
    cap_s="${link%%|*}"
    cap_w="$(printf '%s\n' "$link" | cut -d"|" -f2)"
    sta_s="$(printf '%s\n' "$link" | cut -d"|" -f3)"
    sta_w="$(printf '%s\n' "$link" | cut -d"|" -f4)"
    aspm="$(printf '%s\n' "$link" | cut -d"|" -f5)"
    printf "%-14s %-40s %-10s x%-5s %-10s x%-5s %-s\n" \
      "$bdf" "$name_ids" "$cap_s" "$cap_w" "$sta_s" "$sta_w" "$aspm"
  done < <(LANG=C lspci -Dnn | grep -i 'Ethernet controller')
}

detect_pcie_gpu() {
  _emit_section "PCIe GPU"
  if ! command -v lspci >/dev/null 2>&1; then echo "lspci: not found"; return; fi
  LANG=C lspci -Dnn | grep -Ei 'VGA compatible controller|3D controller' || echo "none"
}

detect_storage() {
  _emit_section "Storage"
  if ! command -v lsblk >/dev/null 2>&1; then echo "lsblk: not found"; return; fi
  lsblk -dn -o NAME,TYPE,TRAN,ROTA,SIZE,MODEL \
    | awk '$2=="disk"{printf "%-8s %-5s rota=%s size=%s model=%s\n",$1,($3?$3:"-"),$4,$5,$6}'

	_emit_section "Storage (USB part)"

  # 只列 USB 類磁碟；其他（SATA/NVMe）你已有函式可沿用
  mapfile -t _disks < <(lsblk -dn -o NAME,TYPE,TRAN | awk '$2=="disk" && $3=="usb"{print $1}')
  if [[ "${#_disks[@]}" -eq 0 ]]; then
    echo "(no USB disks)"
    #return 0
  fi

  printf "%-8s  %s\n" "Device" "USB Link"
  for name in "${_disks[@]}"; do
    node="$(usb_sysnode_for_block "$name" || true)"
    if [[ -n "$node" ]]; then
      printf "%-8s  " "$name"
      usb_summarize_node "$node"
    else
      printf "%-8s  %s\n" "$name" "?"
    fi
  done
	# ...前略（你已有 SATA/USB 段）...

# ---- NVMe ----
	echo
	local printed=0
	while IFS="|" read -r name tran; do
		[[ "$tran" == "nvme" ]] || continue
		if [[ $printed -eq 0 ]]; then
			printf "%-10s %-14s %-10s %-6s %-22s %-6s %-s\n" \
				"NVMe" "BDF" "LnkCapSpd" "CapW" "LnkStaSpd" "StaW" "ASPM"
			printed=1
		fi
		bdf="$(pcie_bdf_from_block "$name" || true)"
		if [[ -n "$bdf" ]]; then
			link="$(pcie_link_info "$bdf")"
			cap_s="${link%%|*}"
			cap_w="$(printf '%s\n' "$link" | cut -d"|" -f2)"
			sta_s="$(printf '%s\n' "$link" | cut -d"|" -f3)"
			sta_w="$(printf '%s\n' "$link" | cut -d"|" -f4)"
			aspm="$(printf '%s\n' "$link" | cut -d"|" -f5)"
		else
			cap_s="?" ; cap_w="?" ; sta_s="?" ; sta_w="?" ; aspm="?"
		fi
		printf "%-10s %-14s %-10s x%-6s %-22s x%-6s %-s\n" \
			"$name" "${bdf:-?}" "$cap_s" "$cap_w" "$sta_s" "$sta_w" "$aspm"
	done < <(lsblk -dn -o NAME,TYPE,TRAN | awk '$2=="disk"{print $1"|" $3}')
	[[ $printed -eq 0 ]] && echo "(no NVMe disks)"

# === Storage (SATA part) ===
	smartctl_install >/dev/null 2>&1 || true
	hdparm_install   >/dev/null 2>&1 || true

	echo "# === Storage (SATA part) ==="
	printf "%-8s %-22s %-12s %-10s %-6s\n" "Device" "Model" "SATA-Proto" "Link" "UDMA"

	while IFS="|" read -r name tran model; do
		case "$tran" in
			ata|sata|scsi) : ;;
			*) continue ;;
		esac

		[[ -z "$model" || "$model" == "-" ]] && model="$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | head -n1)"
		[[ -z "$model" ]] && model="?"

		sum="$(sata_summarize_dev "/dev/${name}")"
		sum="${sum//$'\r'/}"
		[[ "${DEBUG_SATA:-0}" == "1" ]] && echo "[DEBUG] ${name} sum='${sum}'" >&2

		proto="${sum%%|*}"
		rest="${sum#*|}"
		link="${rest%%|*}"
		udma="${rest##*|}"

		[[ -z "$proto" ]] && proto="?"
		[[ -z "$link"  ]] && link="?"
		[[ -z "$udma"  ]] && udma="?"

		printf "%-8s %-22s %-12s %-10s %-6s\n" "$name" "$model" "$proto" "$link" "$udma"
	done < <(lsblk -dn -o NAME,TRAN,MODEL | sed 's/ \+/ /g' | awk '$1!=""{print $1"|" $2 "|" substr($0,index($0,$3))}')
}

# 收集「一次完整快照」
collect_inventory_snapshot() {
  local out="$1"
  : > "$out"

  {  # 這三行也讓它顯示在螢幕
    printf '# Device inventory snapshot (normalized)\n'
    printf 'Host: %s\n'   "$(hostname)"
    printf 'Kernel: %s\n' "$(uname -r)"
  } | tee -a "$out"

  # 每個 detect_* 都鏡寫到檔案 + 螢幕
  detect_cpu           | tee -a "$out"
  detect_ram           | tee -a "$out"
  detect_usb           | tee -a "$out"
  detect_pcie_ethernet | tee -a "$out"
  detect_pcie_gpu      | tee -a "$out"
  detect_storage       | tee -a "$out"
}

# Golden 比對（忽略註解/時間類行）
compare_with_golden() {
  local now="$1" golden="$2" diffout="$3"
  if diff -u -I '^#' -I '^Timestamp' -I '^Session ID' "$golden" "$now" > "$diffout"; then
    return 0
  else
    return 1
  fi
}

# DET013: JSON sidecar, canonical machine-readable record for one pass.
# Written alongside (never replacing) the existing .log/.txt/.diff files.
# "components" is left as an empty object until per-component comparison
# (a later requirement) is implemented.
emit_dev_detect_sidecar() {
  local out_json="$1" k="$2" m="$3" result="$4" snapshot="$5" golden="$6" diffout="$7"
  local ts diff_json="null"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "${diffout}" && -f "${diffout}" ]] && diff_json="\"${diffout}\""
  cat > "${out_json}" <<JSONEOF
{
  "schema_version": "1.0",
  "session_id": "${_session_id}",
  "k": ${k},
  "m": ${m},
  "result": "${result}",
  "timestamp": "${ts}",
  "snapshot_path": "${snapshot}",
  "golden_path": "${golden}",
  "diff_path": ${diff_json},
  "components": {}
}
JSONEOF
}

# DET013: map a pass result string to the standardised exit code.
dev_detect_exit_code_for() {
  case "$1" in
    Pass) echo 0 ;;
    Fail) echo 1 ;;
    Error) echo 2 ;;
    INIT) echo 3 ;;
    *) echo 2 ;;
  esac
}
# =============================================================================
# ---- Loops (持久化) ----
parse_common_cli "$@"
_parse_vpu_flags_from_rem_args
counter_init "dev" "${_target_loop:-1}"
_loops_this_run="$(counter_loops_this_run)"
if [[ "${_loops_this_run}" -le 0 ]]; then
  echo "[INFO] Already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

# ---- Init paths ----
log_dir "" 1
log_root="${_session_log_dir}"

# --- single instance lock ---
LOCK_DIR="${_log_dir}/runlocks"
mkdir -p -- "${LOCK_DIR}"
exec 9> "${LOCK_DIR}/dev-detect.lock"
if ! flock -n 9; then
  echo "[INFO] Another dev_detect is already running; exit."
  exit 0
fi

_entry_full="$(readlink -f "${BASH_SOURCE[0]:-$0}")"

# DET013: snapshot mode hands the persistent loop to an external
# orchestrator -- do not install autorun (it would race with the
# orchestrator's own reboot/power-cycle control).
if [[ "${_snapshot_only}" -eq 0 ]]; then
  # 第一次手動執行時，若沒裝過 systemd autorun，幫自己裝起來
  # 讓它在每次開機自動再跑一次，直到達到 m 次為止。
  autorun_setup "dev" "${_m}" "${_entry_full}" "${REM_ARGS[@]:-}"
fi

: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"

# 測試名 & golden 路徑
#
# DET013: in --snapshot-only mode each invocation is a separate process with
# its own fresh session (the orchestrator calls us once per power cycle), so
# a session-scoped golden would never survive between calls -- every pass
# would see no golden and report INIT forever, verifying nothing. Snapshot
# mode therefore keeps the golden under the stable top-level log dir instead
# of the per-session dir, so it persists across the whole orchestrated run.
# Standalone mode is unchanged: golden stays session-scoped, as today.
: "${_dev_detect_test_name:=dev_detect}"
if [[ "${_snapshot_only}" -eq 1 ]]; then
  golden_dir="${_log_dir}/golden"
else
  golden_dir="${log_root}/golden"
fi
golden_tpl="${golden_dir}/${_dev_detect_test_name}.golden.txt"
mkdir -p -- "${golden_dir}"

# 本次僅跑 1 回（或已完成就退出）
_remaining="$(counter_remaining)"
if (( _remaining <= 0 )); then
  echo "[INFO] Already completed (${_m}/${_m}). Nothing to do."
  # 完成就停用 service（如果還啟用著）
  autorun_disable_if_done "dev" "$(autorun_service_name_for "$_entry_full")" || true
  exit 0
fi
_loops_this_run=1

# ---- Header & start timer ----
_devlog="${log_root}/${_dev_detect_test_name}_${_run_ts}.log"
if [[ ! -f "${_devlog}" ]]; then
  {
    echo "============= Device Detect (${_run_ts}) ============="
    echo "Host: $(hostname)   User: $(whoami)"
    echo "======================================================"
  } > "${_devlog}"
fi
run_time

# ---- Main loop ----
for (( dev_loop=1; dev_loop<=_loops_this_run; dev_loop++ )); do
  #tag="$(counter_next_tag)"; k="${tag%%/*}"; m="${tag##*/}"
  tag="$(counter_next_tag)"; k="${tag%%/*}"; m="${tag##*/}"
  echo "[DEBUG] next_tag=${tag} (k=${k} m=${m})  session=${_session_id}"
  test_progress_set "dev_detect" "$k" "$m"
  echo "[$tag] Device detect..." | tee -a "${_devlog}"

  now_snapshot="${log_root}/${_dev_detect_test_name}_snapshot_${k}_of_${m}_${_run_ts}.txt"
  diffout="${log_root}/${_dev_detect_test_name}_diff_${k}_of_${m}_${_run_ts}.diff"

  if [[ ! -f "${golden_tpl}" ]]; then
    if collect_inventory_snapshot "${now_snapshot}"; then
      cp -f -- "${now_snapshot}" "${golden_tpl}"
      loop_result="INIT"
      { echo "--- Snapshot ${k}/${m} ---"; cat "${now_snapshot}"; } | tee -a "${_devlog}"
    else
      loop_result="Error"
      echo "[ERROR] collect_inventory_snapshot failed" | tee -a "${_devlog}"
    fi
  else
    if collect_inventory_snapshot "${now_snapshot}"; then
      if compare_with_golden "${now_snapshot}" "${golden_tpl}" "${diffout}"; then
        loop_result="Pass"
      else
        loop_result="Fail"
        echo "[DIFF] -> ${diffout}" | tee -a "${_devlog}"
      fi
      { echo "--- Snapshot ${k}/${m} ---"; cat "${now_snapshot}"; } | tee -a "${_devlog}"
    else
      loop_result="Error"
      echo "[ERROR] collect_inventory_snapshot failed" | tee -a "${_devlog}"
    fi
  fi


# ---- Optional VPU check (module) ----
if [[ "${_vpu_enable}" -eq 1 ]]; then
  vpu_loop_result="Pass"
  vpu_tmp="${log_root}/vpu_check_${_session_id}_${k}_of_${m}_RUN.log"
  : > "${vpu_tmp}"
  if vpu_check_run "${vpu_tmp}"; then
    vpu_loop_result="Pass"
  else
    vpu_loop_result="Fail"
  fi
  vpu_final="${log_root}/vpu_check_${_session_id}_${k}_of_${m}_${vpu_loop_result}.log"
  mv -f -- "${vpu_tmp}" "${vpu_final}"
  echo "[$tag] VPU check: ${vpu_loop_result} -> ${vpu_final}" | tee -a "${_devlog}"
fi

  # 依規格命名：dev_detect_<session>_<k>_of_<m>_<result>.log
  final_name="${_dev_detect_test_name}_${_session_id}_${k}_of_${m}_${loop_result}.log"
  # 這輪明細另存一份（彙總仍寫在 _devlog）
  {
    echo "Result: ${loop_result}"
    echo "Golden: ${golden_tpl}"
    echo "Snapshot: ${now_snapshot}"
    [[ -f "${diffout}" ]] && echo "Diff: ${diffout}"
  } > "${log_root}/${final_name}"

  # DET013: machine-readable sidecar, additive to the text log above.
  emit_dev_detect_sidecar \
    "${log_root}/${_dev_detect_test_name}_${_session_id}_${k}_of_${m}_${loop_result}.json" \
    "${k}" "${m}" "${loop_result}" "${now_snapshot}" "${golden_tpl}" \
    "$( [[ -f "${diffout}" ]] && echo "${diffout}" )"
  _last_loop_result="${loop_result}"

  counter_tick
done

echo "" | tee -a "${_devlog}"
elp_time | tee -a "${_devlog}"

_dev_detect_exit_code="$(dev_detect_exit_code_for "${_last_loop_result:-Error}")"

# DET013: snapshot mode never installs autorun and never reboots/powers off --
# loop count and power cycling belong to the external orchestrator.
if [[ "${_snapshot_only}" -eq 1 ]]; then
  echo "[INFO] --snapshot-only: pass complete (${_last_loop_result}). No autorun, no reboot."
  test_progress_clear "dev_detect snapshot complete (${_last_loop_result})."
  exit "${_dev_detect_exit_code}"
fi

# 是否已達成目標?
if (( $(counter_is_done) == 1 )); then
  # 已完成：停用 autorun 服務、不要重開
  autorun_disable_if_done "dev" "$(autorun_service_name_for "$_entry_full")" || true
  echo "[INFO] Completed ${_m}/${_m}. Service disabled. No reboot."
  test_progress_clear "dev_detect completed ${_m}/${_m}. Safe to power off."
  generate_dev_detect_report "${log_root}" | tee -a "${_devlog}"
  exit "${_dev_detect_exit_code}"
else
  # 未完成：等一會兒再重開，讓下一回合接續
  if [[ "${_reset_mode}" == "power-cycle" ]]; then
    echo "[INFO] Progress ${_n}/${_m}. Running power cycling..."
    sleep 60 && poweroff
  else
    echo "[INFO] Progress ${_n}/${_m}. Running rebooting..."
    sleep 60 && reboot
  fi
fi
