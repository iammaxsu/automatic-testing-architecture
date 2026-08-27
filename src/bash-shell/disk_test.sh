#!/usr/bin/env bash
# disk_test.sh ??depends on config.sh & function.sh, with robust logging and fixed summary

#set -uo pipefail  # no `-e` to avoid early aborts
set -Eeuo pipefail

export _disk_test_version
: "${_disk_test_version:="00.00.03"}"

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

# ---- API version check ----
: "${_requires_config_api:=00.00.02}"
: "${_requires_function_api:=00.00.05}"
check_api_versions "disk_test.sh" "${_requires_config_api}" "${_requires_function_api}"

# ---------- Parse CLI parameters ----------
parse_common_cli "$@"

# Parse --sweep from leftover args (parse_common_cli puts unknowns in REM_ARGS)
_sweep=0
if [[ ${#REM_ARGS[@]} -gt 0 ]]; then
  for _rem_a in "${REM_ARGS[@]}"; do
    [[ "${_rem_a}" == "--sweep" ]] && _sweep=1
  done
fi

# ---------- Init logs & session ----------
log_dir "" 1
log_root="${_session_log_dir}"

# FWK038: liveness heartbeat — periodic proof the run has not hung.
test_heartbeat_start "disk_test"


# ---------- Cleanup on exit ----------
# Ensures logs are readable by the login user even if the script is
# interrupted (Ctrl+C, power failure, etc.) before generate_disk_report runs.
trap 'test_heartbeat_stop; fix_log_permissions "${_log_dir:-}" deep' EXIT

# Initialize, m = _target_loop
counter_init "disk" "${_target_loop:-1}"

# Calculate how many loops to do
_loops_this_run=$(counter_loops_this_run)
if [[ "${_loops_this_run}" -le 0 ]]; then
  echo "[INFO] Already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

# parse_loops_arg "${1:-}"

# Timestamp per loop & log folders
: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"
_disklog="${log_root}/disk_test_${_run_ts}.log"
_disksum="${log_root}/disk_summary_${_run_ts}.log"

# ---------- Test Header ----------
## ---------- Start elapsed time now ----------
run_time || true

if [[ ! -f "${_disklog}" ]]; then
  {
    echo "============= Disk Test (${_run_ts}) ============="
    echo "Host: $(hostname)   User: $(whoami)"
    echo "API: ${_function_api_version}"
    echo "=================================================="
    # FWK037: record the configuration this run was measured on.
    collect_system_info
    echo ""
  } > "${_disklog}"
fi

# fio 包裝
run_fio() {
  local _dev="$1" _out="$2"
  shift 2
  sudo fio \
    --name="${_fio_name}" \
    --filename="${_dev}" \
    --group_reporting \
    --direct="${_fio_direct:-1}" \
    --size="${_fio_size:-1g}" \
    --ioengine="${_fio_ioengine:-libaio}" \
    --randrepeat="${_fio_randrepeat:-0}" \
    --end_fsync="${_fio_end_fsync:-1}" \
    --output="${log_root}/${_out}" \
    "$@"
}

# ---------- Sweep mode helper ----------
# Runs a BS × QD × SEQ/RND × read/write matrix for one block device.
# Output: <sweep_dir>/<short>_sweep.csv  and  <sweep_dir>/<short>_sweep.txt
# fio JSON logs per test: <sweep_dir>/<short>_<testname>.json
_sweep_dev() {
  local dev="$1" sweep_dir="$2"
  local short="${dev#/dev/}"
  local csv_path="${sweep_dir}/${short}_sweep.csv"
  local txt_path="${sweep_dir}/${short}_sweep.txt"

  echo "Device,Pattern,RW,BlockSize,QueueDepth,Threads,IOPS,Throughput_MiB_s,Throughput_MB_s,AvgLat_ms,LogFile" \
    > "${csv_path}"

  {
    printf "Disk Sweep Summary  device=%s  threads=%s\n" "${dev}" "${_SWEEP_THREADS}"
    echo "=================================================="
    echo "Columns: IOPS  |  Throughput (MiB/s)  |  Throughput (MB/s)  |  AvgLat (ms)"
    echo "Tip: SEQ -> Throughput (MiB/s); RND 4K -> IOPS + AvgLat"
    echo ""
  } > "${txt_path}"

  local pat rw fio_rw jkey bs qd test_name log_file
  local iops bw_kib lat_ns mibs mbs lat_ms

  # Loop order (pat -> rw -> bs -> qd) gives naturally sorted output.
  for pat in SEQ RND; do
    for rw in read write; do
      [[ "${pat}" == "SEQ" ]] && fio_rw="${rw}" || fio_rw="rand${rw}"
      [[ "${rw}"  == "read" ]] && jkey="read"   || jkey="write"

      for bs in "${_SWEEP_BLOCK_SIZES[@]}"; do
        for qd in "${_SWEEP_QUEUE_DEPTHS[@]}"; do
          test_name="${pat}_${rw}_b${bs}_q${qd}_t${_SWEEP_THREADS}"
          log_file="${sweep_dir}/${short}_${test_name}.json"

          log "[SWEEP] ${dev}  ${test_name}"

          sudo fio \
            --name="${test_name}" \
            --filename="${dev}" \
            --direct=1 \
            --ioengine="${_fio_ioengine:-libaio}" \
            --rw="${fio_rw}" \
            --bs="${bs}" \
            --iodepth="${qd}" \
            --numjobs="${_SWEEP_THREADS}" \
            --size="${_fio_size:-1g}" \
            --ramp_time="${_sweep_warmup:-1}" \
            --runtime="${_sweep_duration:-5}" \
            --time_based \
            --randrepeat=0 \
            --end_fsync=1 \
            --group_reporting \
            --output-format=json \
            --output="${log_file}" 2>/dev/null || true

          iops="" bw_kib="" lat_ns=""
          if [[ -f "${log_file}" ]]; then
            iops=$(   jq -r ".jobs[0].${jkey}.iops"         "${log_file}" 2>/dev/null || echo "")
            bw_kib=$( jq -r ".jobs[0].${jkey}.bw"           "${log_file}" 2>/dev/null || echo "")
            lat_ns=$( jq -r ".jobs[0].${jkey}.lat_ns.mean"  "${log_file}" 2>/dev/null || echo "")
          fi

          if [[ -n "${iops}" && "${iops}" != "null" ]]; then
            iops=$(  awk -v v="${iops}"   'BEGIN{printf "%.2f", v}')
            mibs=$(  awk -v v="${bw_kib}" 'BEGIN{printf "%.3f", v/1024}')
            mbs=$(   awk -v v="${bw_kib}" 'BEGIN{printf "%.3f", v*1024/1000000}')
            lat_ms=$(awk -v v="${lat_ns}" 'BEGIN{printf "%.3f", v/1000000}')

            echo "${dev},${pat},${rw},${bs},${qd},${_SWEEP_THREADS},${iops},${mibs},${mbs},${lat_ms},${log_file}" \
              >> "${csv_path}"
            printf "%-3s %-5s  bs=%-6s q=%-4s  IOPS=%12s  Thpt=%10s MiB/s  %10s MB/s  AvgLat=%9s ms\n" \
              "${pat}" "${rw}" "${bs}" "${qd}" "${iops}" "${mibs}" "${mbs}" "${lat_ms}" \
              >> "${txt_path}"
          else
            echo "${dev},${pat},${rw},${bs},${qd},${_SWEEP_THREADS},,,,,[no parse] ${log_file}" \
              >> "${csv_path}"
            printf "%-3s %-5s  bs=%-6s q=%-4s  [no data]\n" \
              "${pat}" "${rw}" "${bs}" "${qd}" \
              >> "${txt_path}"
          fi
        done
      done
      echo "" >> "${txt_path}"
    done
  done

  log "Sweep CSV: ${csv_path}"
  log "Sweep TXT: ${txt_path}"
  echo ""
  echo "Sweep results:"
  echo "  CSV: ${csv_path}"
  echo "  TXT: ${txt_path}"
}

log "==== disk_test.sh ===="
log "Script   : ${_entry}"
log "LogPath  : ${log_root}"
log "Target m : ${_m}    Done n: ${_n}    This run loops: ${_loops_this_run}"
log "============================================="

# ---------- Ensure tools ----------
if command -v fio >/dev/null 2>&1; then :; else fio_install || true; fi
command -v lsblk >/dev/null 2>&1 || { log "ERROR: lsblk not found"; exit 1; }
command -v findmnt >/dev/null 2>&1 || { log "ERROR: findmnt not found"; exit 1; }
command -v blkid >/dev/null 2>&1 || true

# ---------- Helpers ----------
normalize_dev() { local n="$1"; while [[ "$n" == /dev/* ]]; do n="${n#/dev/}"; done; echo "/dev/${n}"; }
is_block() { local n; n="$(normalize_dev "$1")"; lsblk -dn -o NAME "$n" &>/dev/null; }
resolve_ref() {
  local ref="$1"
  if [[ "$ref" == UUID=* ]]; then blkid -U "${ref#UUID=}" 2>/dev/null || echo ""
  elif [[ "$ref" == PARTUUID=* ]]; then blkid -t PARTUUID="${ref#PARTUUID=}" -o device 2>/dev/null || echo ""
  else echo "$ref"; fi
}
parents_to_disks() {
  local node; node="$(normalize_dev "$1")"; is_block "$node" || return 0
  local t; t="$(lsblk -no TYPE "$node" 2>/dev/null || echo "")"
  if [[ "$t" == "disk" ]]; then basename "$node"; return; fi
  declare -A seen=(); local q=("$node")
  while ((${#q[@]})); do
    local cur="${q[0]}"; q=("${q[@]:1}"); [[ -n "${seen[$cur]:-}" ]] && continue; seen["$cur"]=1
    while IFS= read -r line; do
      local name type pk; name="$(awk '{print $1}' <<<"$line")"; type="$(awk '{print $2}' <<<"$line")"; pk="$(awk '{print $3}' <<<"$line")"
      if [[ "$name" == "$cur" ]]; then
        if [[ "$type" == "disk" ]]; then basename "$name"
        elif [[ -n "$pk" && "$pk" != "-" ]]; then IFS=',' read -ra pks <<<"$pk"; for p in "${pks[@]}"; do q+=("$(normalize_dev "$p")"); done; fi
      fi
    done < <(lsblk -nrpo NAME,TYPE,PKNAME "$cur" 2>/dev/null || true)
  done | sed 's|/dev/||' | sort -u
}
declare -A _UNSAFE=()
mark_disk_parent() {
  local src="$1" why="$2"; [[ -z "$src" ]] && return
  local dev; dev="$(resolve_ref "$src")"; [[ -z "$dev" ]] && dev="$src"
  dev="$(normalize_dev "$dev")"; is_block "$dev" || { log "Skip non-block: ${src} (${why})"; return; }
  while IFS= read -r d; do [[ -n "$d" ]] && _UNSAFE["$d"]="reason:${why} source:${src}"; done < <(parents_to_disks "$dev")
}

# ---------- Build SAFE target list ----------
log "Stage: Collect mounted block sources"
while IFS= read -r src; do [[ "$src" == /dev/* ]] || continue; is_block "$src" || continue; mark_disk_parent "$src" "mounted"; done < <(findmnt -rn -o SOURCE 2>/dev/null | sort -u)

for mp in / /boot /boot/efi; do
  src="$(findmnt -nr -o SOURCE --target "$mp" 2>/dev/null || true)"
  [[ -n "$src" ]] && mark_disk_parent "$src" "critical:${mp}"
done

if [[ -r /proc/swaps ]]; then
  while read -r sw; do [[ "$sw" == /dev/* ]] || continue; is_block "$sw" || continue; mark_disk_parent "$sw" "swap"; done < <(awk 'NR>1{print $1}' /proc/swaps)
fi

if [[ -r /etc/fstab ]]; then
  while read -r ref; do
    dev="$(resolve_ref "$ref")"
    [[ -n "$dev" && "$dev" == /dev/* ]] || continue
    is_block "$dev" || continue
    mark_disk_parent "$dev" "fstab"
  done < <(awk '!/^#/ && NF>=2 {print $1}' /etc/fstab | sort -u)
fi

mapfile -t _ALL_DISKS < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

# Exclude zero-capacity disks: BMC virtual media, empty card readers, etc.
for d in "${_ALL_DISKS[@]}"; do
  [[ -n "${_UNSAFE[$d]:-}" ]] && continue
  _sz_bytes="$(lsblk -dn -b -o SIZE "/dev/${d}" 2>/dev/null | tr -d ' \n' || echo 0)"
  if [[ -z "${_sz_bytes}" || "${_sz_bytes}" -eq 0 ]]; then
    _UNSAFE["$d"]="reason:zero-size source:/dev/${d}"
  fi
done

log "---- Exclusion report (OS / in-use) ----"
for d in "${_ALL_DISKS[@]}"; do
  if [[ -n "${_UNSAFE[$d]:-}" ]]; then
    log "Exclude /dev/${d} -> ${_UNSAFE[$d]}"
  fi
done
log "----------------------------------------"

SAFE=()
for d in "${_ALL_DISKS[@]}"; do
  if [[ -z "${_UNSAFE[$d]:-}" ]]; then 
    SAFE+=("/dev/${d}")
  fi
done

if [[ ${#SAFE[@]} -eq 0 ]]; then
  log "No SAFE disks were found. Exit."
  exit 0
fi

log "SAFE targets: ${SAFE[*]}"
log "WARNING: Destructive fio on: ${SAFE[*]}"
if [[ "${YES_I_UNDERSTAND:-0}" != "1" ]]; then
  read -r -p "Type YES to proceed: " _ans || true
  if [[ "${_ans:-}" != "YES" ]]; then 
    log "Cancelled."
    exit 0
  fi
fi

# ---------- Sweep mode ----------
if [[ "${_sweep}" == "1" ]]; then
  _sweep_run_dir="${log_root}/sweep_${_run_ts}"
  mkdir -p "${_sweep_run_dir}"
  log "Sweep mode: ${#_SWEEP_BLOCK_SIZES[@]} block sizes × ${#_SWEEP_QUEUE_DEPTHS[@]} queue depths × 4 patterns"
  log "Output dir: ${_sweep_run_dir}"

  for dev in "${SAFE[@]}"; do
    _sweep_dev "${dev}" "${_sweep_run_dir}"
  done

  test_progress_clear "sweep completed. Safe to power off."
  exit 0
fi

for (( loop_n=1; loop_n<=_loops_this_run; loop_n++ )); do
  echo "------------------------------------------------------------"
  echo "[$(counter_next_tag)] Disk test..."
  km="$(counter_next_tag)"
  k="${km%%/*}"
  mm="${km##*/}"
  test_progress_set "disk_test" "${k}" "${mm}"
  test_heartbeat_phase "loop ${k}/${mm}"
  log "----- Iteration ${k} of ${mm} -----"

  n="${k}"   # 這一輪的編號（避免覆蓋）
 # for dev in "${SAFE[@]}"; do
 #   _short="${dev#/dev/}"
 #   log "[RUN] ${dev} (loop ${n})"
 #   run_fio "$dev" "${_short}_SEQ1MQ8T1_Read_${n}_of_${_target_loop}.log"   --rw=read      --bs=1m --iodepth=8  --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_SEQ1MQ8T1_Write_${n}_of_${_target_loop}.log"  --rw=write     --bs=1m --iodepth=8  --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_SEQ1MQ1T1_Read_${n}_of_${_target_loop}.log"   --rw=read      --bs=1m --iodepth=1  --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_SEQ1MQ1T1_Write_${n}_of_${_target_loop}.log"  --rw=write     --bs=1m --iodepth=1  --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_RND4KQ32T1_Read_${n}_of_${_target_loop}.log"  --rw=randread  --bs=4k --iodepth=32 --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_RND4KQ32T1_Write_${n}_of_${_target_loop}.log" --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_RND4KQ1T1_Read_${n}_of_${_target_loop}.log"   --rw=randread  --bs=4k --iodepth=1  --numjobs=1 --size=1g --runtime=5
 #   run_fio "$dev" "${_short}_RND4KQ1T1_Write_${n}_of_${_target_loop}.log"  --rw=randwrite --bs=4k --iodepth=1  --numjobs=1 --size=1g --runtime=5
 # done    

for dev in "${SAFE[@]}"; do
  _short="${dev#/dev/}"
  log "[RUN] ${dev} (loop ${n})"

  # 依裝置型別建立要跑的測試清單（讀自 config.sh）
  build_fio_tests_for_dev "$dev"

  # 逐項執行：BASE RW BS IODEPTH NUMJOBS
  for spec in "${FIO_TESTS[@]}"; do
    read -r BASE RW BS IOD NJ <<<"$spec"
    # 檔名：<短名>_<BASE>_<Read|Write>_<n>_of_<目標>.log
    # （將 randread/randwrite 轉成人眼友善的 Read/Write 兩類）
    case "$RW" in
      read|randread)   KIND="Read"  ;;
      write|randwrite) KIND="Write" ;;
      *)               KIND="$RW"   ;;
    esac
    out="${_short}_${BASE}_${KIND}_${n}_of_${_target_loop}.log"
    run_fio "$dev" "$out" --rw="$RW" --bs="$BS" --iodepth="$IOD" --numjobs="$NJ"
  done
done

# ---------- Summary ----------
#: > "${_disksum}"
#extract_bw() {
#  local _kind="$1" _file="$2"
#  grep -iE "^\s*${_kind,,}:" "$_file" \
#    | sed -n 's/.*bw=\([0-9.]\+\)[KMG]i\?B\/s (\([0-9.]\+\)[KMG]B\/s.*/\1 \2/p' \
#    | head -n1
#}
#
#for dev in "${SAFE[@]}"; do
#  _short="${dev#/dev/}"
#  {
#    echo "Disk: $_short"
#    patterns=(
#      "SEQ1MQ8T1 Read"
#      "SEQ1MQ8T1 Write"
#      "SEQ1MQ1T1 Read"
#      "SEQ1MQ1T1 Write"
#      "RND4KQ32T1 Read"
#      "RND4KQ32T1 Write"
#      "RND4KQ1T1 Read"
#      "RND4KQ1T1 Write"
#    )
#    for item in "${patterns[@]}"; do
#      base="${item%% *}"
#      _kind="${item##* }"
#      mib_total=0; mb_total=0; cnt=0
#      for ((n=1;n<=_m;n++)); do
#        for f in "${log_root}/${_short}_${base}_${_kind}_${n}_of_"*.log; do
#          [[ -f "$f" ]] || continue
#          v="$(extract_bw "$_kind" "$f")"
#          [[ -n "$v" ]] || continue
#
#          mib="$(echo "$v" | awk '{print $1}')"
#          mb="$(echo "$v"  | awk '{print $2}')"
#
#          # 加總（用 awk 避免 bash 浮點）
#          mib_total=$(awk -v a="$mib_total" -v b="$mib" 'BEGIN{print a+b}')
#          mb_total=$(awk -v a="$mb_total" -v b="$mb"  'BEGIN{print a+b}')
#          cnt=$((cnt+1))
#        done
#      done
#      if [[ $cnt -gt 0 ]]; then
#        mib_avg=$(awk -v a="$mib_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
#        mb_avg=$(awk -v a="$mb_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
#        printf "  %-18s %-5s : avg=%s MiB/s (%s MB/s)\n" "$base" "$_kind" "$mib_avg" "$mb_avg"
#      else
#        printf "  %-18s %-5s : no data\n" "$base" "$_kind"
#      fi
#    done
#    echo
#  } >> "${_disksum}"
#done
# ---------- Summary ----------
: > "${_disksum}"

# Ensure jq is available for result.json emission (LOG015)
jq_install || true

# Collect structured results for result.json. Built up as a JSON array of
# device objects, each containing a patterns array. Final emit uses jq to
# wrap this in the LOG020 schema.
_jq_devices='[]'

# 從 fio 檔抓讀/寫 BW；大小寫不敏感；回傳 "MiB/s MB/s"
# Handles fio's full unit space (BUG0024):
#   IEC binary side: bw=NUMBER<unit>iB/s — unit ∈ {"", K, M, G, T} (uppercase)
#   SI decimal side: (NUMBER<unit>B/s)   — unit ∈ {"", k, M, G, T}
#                                          ^ NOTE: fio uses LOWERCASE k for SI thousand
# Output canonicalised to MiB/s and MB/s regardless of input scale.
extract_bw() {
  local kind="$1" file="$2"
  local line
  line="$(grep -iE "^\s*${kind,,}:" "$file" | head -n1)"
  [[ -z "$line" ]] && return

  # Pull out the IEC and SI fragments
  local iec_match si_match
  iec_match="$(echo "$line" | grep -oiE 'bw=[0-9.]+[KMGT]?i?B/s' | head -n1)"
  si_match="$( echo "$line" | grep -oE  '\([0-9.]+[kKMGT]?B/s\)'  | head -n1)"
  [[ -z "$iec_match" || -z "$si_match" ]] && return

  # Parse number + unit prefix. Upper-case the unit so the case statement
  # below only needs to handle K/M/G/T.
  local iec_num iec_unit si_num si_unit
  iec_num="$( echo "$iec_match" | sed -E 's/^[Bb][Ww]=([0-9.]+).*/\1/')"
  iec_unit="$(echo "$iec_match" | sed -E 's/^[Bb][Ww]=[0-9.]+([KMGTkmgt]?)i?B\/s$/\1/' | tr 'kmgt' 'KMGT')"
  si_num="$(  echo "$si_match"  | sed -E 's/^\(([0-9.]+).*/\1/')"
  si_unit="$( echo "$si_match"  | sed -E 's/^\([0-9.]+([KMGTkmgt]?)B\/s\)$/\1/' | tr 'kmgt' 'KMGT')"

  # Canonicalise to MiB/s (IEC: 1 MiB = 1024 KiB; 1 GiB = 1024 MiB)
  local mib mb
  case "$iec_unit" in
    "") mib=$(awk -v n="$iec_num" 'BEGIN{printf "%.6f", n/1048576}') ;;
    K)  mib=$(awk -v n="$iec_num" 'BEGIN{printf "%.6f", n/1024}')    ;;
    M)  mib="$iec_num"                                                ;;
    G)  mib=$(awk -v n="$iec_num" 'BEGIN{printf "%.6f", n*1024}')    ;;
    T)  mib=$(awk -v n="$iec_num" 'BEGIN{printf "%.6f", n*1048576}') ;;
  esac

  # Canonicalise to MB/s (SI: 1 MB = 1000 kB; 1 GB = 1000 MB)
  case "$si_unit" in
    "") mb=$(awk -v n="$si_num" 'BEGIN{printf "%.6f", n/1000000}') ;;
    K)  mb=$(awk -v n="$si_num" 'BEGIN{printf "%.6f", n/1000}')    ;;
    M)  mb="$si_num"                                                ;;
    G)  mb=$(awk -v n="$si_num" 'BEGIN{printf "%.6f", n*1000}')    ;;
    T)  mb=$(awk -v n="$si_num" 'BEGIN{printf "%.6f", n*1000000}') ;;
  esac

  echo "$mib $mb"
}

for dev in "${SAFE[@]}"; do
  short="${dev#/dev/}"

  # 針對這顆裝置挑「自己的 8 條」pattern（來自 config.sh）
  build_fio_summary_patterns_for_dev "$dev"

  # Determine device type for result.json (sata|nvme)
  if fio_is_nvme "$dev"; then
    _dev_type="nvme"
  else
    _dev_type="sata"
  fi

  # Per-device patterns array (JSON, accumulated across SUMMARY_PATTERNS)
  _jq_patterns='[]'

  {
    echo "Disk: $short"
    for item in "${SUMMARY_PATTERNS[@]}"; do
      base="${item%% *}"   # 例：SEQ1MQ8T1 / SEQ128KQ32T1 / RND4KQ32T1 ...
      kind="${item##* }"   # Read / Write
      direction="${kind,,}"   # read / write (lowercase for JSON)

      mib_total=0; mb_total=0; cnt=0
      # 掃 1.._m（m 是本批次目標回合），只統計這顆該 pattern 的檔案
      for ((n=1; n<=_m; n++)); do
        # 檔名樣式：<short>_<BASE>_<Kind>_<n>_of_*.log
        for f in "${log_root}/${short}_${base}_${kind}_${n}_of_"*.log; do
          [[ -f "$f" ]] || continue
          v="$(extract_bw "$kind" "$f")"
          [[ -n "$v" ]] || continue
          mib="$(echo "$v" | awk '{print $1}')"
          mb="$(echo "$v"  | awk '{print $2}')"
          mib_total=$(awk -v a="$mib_total" -v b="$mib" 'BEGIN{print a+b}')
          mb_total=$(awk -v a="$mb_total" -v b="$mb"  'BEGIN{print a+b}')
          cnt=$((cnt+1))
        done
      done

      if [[ $cnt -gt 0 ]]; then
        mib_avg=$(awk -v a="$mib_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
        mb_avg=$(awk -v a="$mb_total" -v c="$cnt" 'BEGIN{printf "%.3f", a/c}')
        printf "  %-18s %-5s : avg=%s MiB/s (%s MB/s)\n" "$base" "$kind" "$mib_avg" "$mb_avg"

        # Append to JSON patterns. verdict=UNKNOWN until DSK005 thresholds
        # exist; measurements record actual numbers regardless.
        _jq_patterns=$(jq \
          --arg     name      "$base" \
          --arg     dir       "$direction" \
          --argjson mibs      "$mib_avg" \
          --argjson mbs       "$mb_avg" \
          --arg     verdict   "UNKNOWN" \
          '. += [{
            name: $name,
            direction: $dir,
            measurements: { avg_mibs: $mibs, avg_mbs: $mbs },
            verdict: $verdict
          }]' <<<"$_jq_patterns")
      else
        # 這顆裝置該有的 8 條之一，但目前找不到資料 → 顯示 no data
        printf "  %-18s %-5s : no data\n" "$base" "$kind"

        # Pattern was expected but no fio output found → SKIPPED.
        _jq_patterns=$(jq \
          --arg name    "$base" \
          --arg dir     "$direction" \
          --arg verdict "SKIPPED" \
          '. += [{
            name: $name,
            direction: $dir,
            measurements: null,
            verdict: $verdict
          }]' <<<"$_jq_patterns")
      fi
    done
    echo
  } >> "${_disksum}"

  # Append this device (with its accumulated patterns) into _jq_devices
  _jq_devices=$(jq \
    --arg     name     "$dev" \
    --arg     type     "$_dev_type" \
    --argjson patterns "$_jq_patterns" \
    '. += [{ name: $name, type: $type, patterns: $patterns }]' <<<"$_jq_devices")
done

counter_tick

done  # for loop_n
echo "" | tee -a "${_disklog}"
elp_time | tee -a "${_disklog}"
log "Summary written to: ${_disksum}"

# ---------- Emit result.json (LOG015 / LOG017 / LOG020) ----------
_resultjson="${log_root}/disk_test_${_run_ts}.result.json"

# Counts by verdict, derived from _jq_devices
_total_count=$(  jq '[.[] | .patterns[]] | length'                                <<<"$_jq_devices")
_pass_count=$(   jq '[.[] | .patterns[] | select(.verdict=="PASS")]    | length'  <<<"$_jq_devices")
_fail_count=$(   jq '[.[] | .patterns[] | select(.verdict=="FAIL")]    | length'  <<<"$_jq_devices")
_unknown_count=$(jq '[.[] | .patterns[] | select(.verdict=="UNKNOWN")] | length'  <<<"$_jq_devices")
_skipped_count=$(jq '[.[] | .patterns[] | select(.verdict=="SKIPPED")] | length'  <<<"$_jq_devices")
_error_count=$(  jq '[.[] | .patterns[] | select(.verdict=="ERROR")]   | length'  <<<"$_jq_devices")

_summary_json=$(jq -n \
  --argjson total   "$_total_count" \
  --argjson passed  "$_pass_count" \
  --argjson failed  "$_fail_count" \
  --argjson unknown "$_unknown_count" \
  --argjson skipped "$_skipped_count" \
  --argjson error   "$_error_count" \
  '{ total: $total, passed: $passed, failed: $failed,
     unknown: $unknown, skipped: $skipped, error: $error }')

_details_json=$(jq -n --argjson devices "$_jq_devices" '{ devices: $devices }')

# Overall verdict roll-up:
#   any ERROR → ERROR; any FAIL → FAIL;
#   all PASS (and total>0) → PASS;
#   otherwise (mix of UNKNOWN/SKIPPED/PASS, or total==0) → UNKNOWN
if (( _error_count > 0 )); then
  _verdict="ERROR"
elif (( _fail_count > 0 )); then
  _verdict="FAIL"
elif (( _pass_count == _total_count && _total_count > 0 )); then
  _verdict="PASS"
else
  _verdict="UNKNOWN"
fi

emit_result_json \
  --test-name    disk_test \
  --test-version "${_disk_test_version:-unknown}" \
  --verdict      "$_verdict" \
  --summary-json "$_summary_json" \
  --details-json "$_details_json" \
  --output       "$_resultjson"

log "Result JSON written to: ${_resultjson}"

test_progress_clear "disk_test completed. Safe to power off."
generate_disk_report "${log_root}"
