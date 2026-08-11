# Project Status

_Generated 2026-08-11 05:40 · regenerate with `python scripts/stats.py > STATUS.md`_

## Requirements

**Total:** 150

### By priority

| Priority | Count |
| --- | --- |
| Must | 126 |
| Should | 22 |
| — | 2 |

### By status

| Status | Count |
| --- | --- |
| proposed | 106 |
| implementing | 11 |
| implemented | 33 |

```mermaid
pie showData title Requirements by status
    "proposed" : 106
    "implementing" : 11
    "implemented" : 33
```

### By section

| Section | Total | Verified | Not done |
| --- | --- | --- | --- |
| CMP | 6 | 0 | 6 |
| DET | 13 | 0 | 12 |
| DOC | 4 | 0 | 4 |
| DSK | 10 | 0 | 8 |
| FUN | 7 | 0 | 6 |
| FWK | 38 | 0 | 30 |
| LOG | 26 | 0 | 23 |
| NET | 18 | 0 | 18 |
| PWR | 16 | 0 | 1 |
| SET | 7 | 0 | 4 |
| SLP | 5 | 0 | 5 |

### Must-priority requirements not yet implemented

| ID | Status | Title |
| --- | --- | --- |
| [CMP001](requirements/CMP001.md) | proposed | Primary Supported OS Declaration |
| [CMP003](requirements/CMP003.md) | proposed | Distribution-Aware Package Installation |
| [CMP004](requirements/CMP004.md) | proposed | Required Tool Declaration and Auto-Install |
| [CMP005](requirements/CMP005.md) | proposed | Graceful Handling of Unavailable Tools |
| [CMP006](requirements/CMP006.md) | proposed | Bug OS Column Scope Convention |
| [DET001](requirements/DET001.md) | proposed | CPU Model and Core Count |
| [DET002](requirements/DET002.md) | implementing | RAM Capacity, DIMM Population & Usability Verification |
| [DET003](requirements/DET003.md) | proposed | Network Interface Model and Count |
| [DET004](requirements/DET004.md) | proposed | USB Device Model and Speed |
| [DET005](requirements/DET005.md) | proposed | Storage Device Model and Capacity |
| [DET006](requirements/DET006.md) | proposed | PCIe Link Speed and Width |
| [DET007](requirements/DET007.md) | proposed | Concise Summary Log |
| [DET008](requirements/DET008.md) | proposed | Full lshw Reference Log |
| [DET009](requirements/DET009.md) | proposed | Golden Reference Comparison |
| [DET010](requirements/DET010.md) | proposed | Configurable Golden Reference Path |
| [DET011](requirements/DET011.md) | proposed | Diff Output in Test Log |
| [DET013](requirements/DET013.md) | implementing | Snapshot Mode and Machine-Readable Per-Run Result |
| [DOC003](requirements/DOC003.md) | proposed | Bug Status Vocabulary |
| [DOC004](requirements/DOC004.md) | proposed | Test Verdict Vocabulary |
| [DSK001](requirements/DSK001.md) | proposed | Storage Device Enumeration |
| [DSK002](requirements/DSK002.md) | proposed | OS Partition Exclusion from Destructive Tests |
| [DSK003](requirements/DSK003.md) | proposed | Explicit Confirmation Before Destructive Tests |
| [DSK004](requirements/DSK004.md) | implementing | Separate fio Profiles for SATA and NVMe |
| [DSK005](requirements/DSK005.md) | proposed | PASS/FAIL Verdict per fio Pattern |
| [DSK006](requirements/DSK006.md) | proposed | Disk Test Summary Table Format |
| [DSK008](requirements/DSK008.md) | proposed | Invalid Block Device Filtering |
| [FUN001](requirements/FUN001.md) | proposed | Auto-Detect and Install iperf3 |
| [FUN002](requirements/FUN002.md) | proposed | Auto-Detect and Install fio |
| [FUN003](requirements/FUN003.md) | proposed | Total Elapsed Wall-Clock Time |
| [FUN004](requirements/FUN004.md) | proposed | Idempotent Tool Installation |
| [FUN005](requirements/FUN005.md) | proposed | Shared log() Interface |
| [FUN006](requirements/FUN006.md) | proposed | Exactly-Once Counter Semantics |
| [FWK001](requirements/FWK001.md) | proposed | Snake Case Naming |
| [FWK003](requirements/FWK003.md) | proposed | Private Function Naming |
| [FWK004](requirements/FWK004.md) | proposed | Config and Function as Public API |
| [FWK005](requirements/FWK005.md) | proposed | Semantic Version Strings |
| [FWK006](requirements/FWK006.md) | proposed | Config API Version Declaration |
| [FWK007](requirements/FWK007.md) | proposed | Function API Version Declaration |
| [FWK008](requirements/FWK008.md) | proposed | Function–Config Version Compatibility Check |
| [FWK009](requirements/FWK009.md) | proposed | Test Script Version Verification at Startup |
| [FWK010](requirements/FWK010.md) | proposed | Config Sourced Before Function |
| [FWK011](requirements/FWK011.md) | proposed | Strict Error Handling |
| [FWK012](requirements/FWK012.md) | proposed | Session ID for Test Run Identity |
| [FWK013](requirements/FWK013.md) | proposed | Resume After Power Cycle |
| [FWK014](requirements/FWK014.md) | proposed | 4-Bit Sleep State Encoding |
| [FWK015](requirements/FWK015.md) | proposed | Loop Count Argument |
| [FWK016](requirements/FWK016.md) | proposed | Headless / Non-Interactive Execution |
| [FWK018](requirements/FWK018.md) | proposed | Detached Execution via Session Manager |
| [FWK020](requirements/FWK020.md) | proposed | DUT-Side Test Completion Detection |
| [FWK021](requirements/FWK021.md) | proposed | Flat Deployment Directory on DUT |
| [FWK022](requirements/FWK022.md) | proposed | Result Packaging and Retrieval |
| [FWK024](requirements/FWK024.md) | proposed | Non-Interactive Flags via Environment Variables |
| [FWK025](requirements/FWK025.md) | proposed | Script Self-Elevation to Root |
| [FWK026](requirements/FWK026.md) | proposed | Output File Ownership Restoration |
| [FWK027](requirements/FWK027.md) | proposed | No Silent State Mutation in Helper Functions |
| [FWK032](requirements/FWK032.md) | proposed | In-Test DUT User Notification |
| [FWK033](requirements/FWK033.md) | proposed | Privilege Precondition Check |
| [FWK036](requirements/FWK036.md) | proposed | Cross-Language Feature Parity |
| [LOG002](requirements/LOG002.md) | proposed | All Test Output in logs/ |
| [LOG003](requirements/LOG003.md) | proposed | Log Filename Includes Test Name |
| [LOG004](requirements/LOG004.md) | proposed | Log Filename Includes Loop Number |
| [LOG005](requirements/LOG005.md) | proposed | Log Filename Includes ISO 8601 Timestamp |
| [LOG006](requirements/LOG006.md) | proposed | Log Filename Includes Test Result |
| [LOG007](requirements/LOG007.md) | proposed | Log File Extension |
| [LOG008](requirements/LOG008.md) | proposed | Discrete-Mode Log Filename Order |
| [LOG009](requirements/LOG009.md) | proposed | Log Directory Verification at Startup |
| [LOG010](requirements/LOG010.md) | proposed | Elapsed Time Reporting |
| [LOG011](requirements/LOG011.md) | proposed | Per-fio-Invocation Log File |
| [LOG012](requirements/LOG012.md) | proposed | fio Log Filename Convention |
| [LOG013](requirements/LOG013.md) | proposed | Disk Test Average Throughput Summary |
| [LOG014](requirements/LOG014.md) | proposed | Log Entry Timestamp and Level Prefix |
| [LOG015](requirements/LOG015.md) | proposed | Machine-Readable result.json |
| [LOG017](requirements/LOG017.md) | proposed | Three-Artefact Output Model and Two Logging Modes |
| [LOG018](requirements/LOG018.md) | proposed | HTML Report Generated from result.json |
| [LOG020](requirements/LOG020.md) | proposed | Minimum result.json Fields |
| [LOG021](requirements/LOG021.md) | proposed | Output File Ownership |
| [LOG022](requirements/LOG022.md) | proposed | ISO 8601 Timestamp Consistency |
| [LOG023](requirements/LOG023.md) | proposed | Test Session Identity and Resume |
| [NET001](requirements/NET001.md) | proposed | Enumerate enp and eno Interfaces |
| [NET002](requirements/NET002.md) | proposed | Isolated Loopback Testing (Namespace / Weak Host Model) |
| [NET003](requirements/NET003.md) | proposed | Clean Namespace State Before Testing |
| [NET004](requirements/NET004.md) | proposed | Test at All Advertised Link Speeds |
| [NET005](requirements/NET005.md) | proposed | ICMP Connectivity Verification |
| [NET006](requirements/NET006.md) | proposed | iperf3 Throughput in Four Combinations |
| [NET007](requirements/NET007.md) | proposed | Configurable iperf3 Duration |
| [NET008](requirements/NET008.md) | proposed | Verdict Assignment per Test Item |
| [NET011](requirements/NET011.md) | implementing | NIC Include/Exclude Lists |
| [NET013](requirements/NET013.md) | proposed | iperf3 Log Filename Convention |
| [NET016](requirements/NET016.md) | implementing | NIC Error / Discard Counter Verification |
| [SET001](requirements/SET001.md) | proposed | Tunable Parameters in config Only |
| [SET002](requirements/SET002.md) | proposed | Utility Functions in function Only |
| [SET003](requirements/SET003.md) | proposed | config Contains No Executable Logic |
| [SET004](requirements/SET004.md) | proposed | Environment Variable Overrides for Config Defaults |
| [SLP001](requirements/SLP001.md) | proposed | ACPI Sleep State Detection |
| [SLP002](requirements/SLP002.md) | proposed | Configurable Pre-Sleep Delay |
| [SLP003](requirements/SLP003.md) | proposed | Configurable Wake Timer |
| [SLP004](requirements/SLP004.md) | proposed | Post-Wake Service Verification |
| [SLP005](requirements/SLP005.md) | proposed | Atomic Sleep State Bit-Field Update |

## Bugs

**Total:** 52

### By status

| Status | Count |
| --- | --- |
| open | 13 |
| in-progress | 1 |
| resolved | 26 |
| closed | 10 |
| invalid | 2 |

```mermaid
pie showData title Bugs by status
    "open" : 13
    "in-progress" : 1
    "resolved" : 26
    "closed" : 10
    "invalid" : 2
```

### By OS

| OS | Count |
| --- | --- |
| Ubuntu 24.04 LTS | 27 |
| Ubuntu 26.04 LTS | 21 |
| Windows 11 | 13 |
| Windows 11 (zh-TW) | 2 |
| Windows 11 (English / en-US) | 1 |
| Windows 11 (Traditional Chinese / zh-TW) | 1 |

### Open bugs (oldest first)

| ID | Created | Status | Title |
| --- | --- | --- | --- |
| [BUG0003](bugs/open/BUG0003-safe-to-power-off-message-misleading.md) | 2026-04-30 | open | Safe to power off message misleading |
| [BUG0004](bugs/open/BUG0004-fio-log-filenames-missing-timestamp-and-result.md) | 2026-05-05 | open | fio log filenames missing timestamp and result |
| [BUG0005](bugs/open/BUG0005-date2-not-initialised-by-setup-session.md) | 2026-05-05 | open | _date2 not initialised by setup_session |
| [BUG0006](bugs/open/BUG0006-disk-test-sh-does-not-call-run-time-at-start.md) | 2026-05-05 | open | disk_test.sh does not call run_time at start |
| [BUG0007](bugs/open/BUG0007-wall-broadcast-progress-message-uses-1-1-eta-0s.md) | 2026-05-05 | open | wall broadcast progress message uses 1/1 ETA 0s |
| [BUG0008](bugs/open/BUG0008-ansible-fetches-entire-logs-dir-instead-of-current.md) | 2026-05-05 | open | Ansible fetches entire logs dir instead of current session only |
| [BUG0012](bugs/open/BUG0012-dev-detect-first-run-snapshot-vs-golden-template-n.md) | 2026-05-05 | open | dev_detect first-run snapshot vs golden template not visually distinguishable |
| [BUG0013](bugs/open/BUG0013-log-entries-do-not-include-log-level-prefix.md) | 2026-05-05 | open | Log entries do not include log level prefix |
| [BUG0015](bugs/open/BUG0015-net-test-sh-consumes-the-ssh-lifeline-nic.md) | 2026-05-05 | open | net_test.sh consumes the SSH lifeline NIC |
| [BUG0016](bugs/open/BUG0016-dimm8-row-formatting-differs-from-dimm1-7-in-detec.md) | 2026-05-05 | open | DIMM8 row formatting differs from DIMM1-7 in detect_ram output |
| [BUG0020](bugs/open/BUG0020-sleep-test-not-yet-integrated-or-verified.md) | 2026-05-08 | open | sleep_test not yet integrated or verified |
| [BUG0022](bugs/open/BUG0022-the-notification-is-misleading.md) | 2026-05-14 | open | The notification is misleading |
| [BUG0036](bugs/open/BUG0036-reboot-slow-boot-misjudged-dead.md) | 2026-06-30 | in-progress | `reboot.py` misjudges a slow-booting DUT as dead |
| [BUG0046](bugs/open/BUG0046-calibrate-no-boot-power-down-race.md) | 2026-08-03 | open | isolated NO_BOOT during calibration; off-time is measured from network-offline, not confirmed power-off |

## Traceability

### Requirements with associated bugs

| Requirement | Bug | Bug status |
| --- | --- | --- |
| CMP005 | [BUG0011](bugs/closed/BUG0011-dev-detect-aborts-silently-when-an-upstream-detect.md) | closed |
| DET002 | [BUG0039](bugs/closed/BUG0039-dimm-populated-but-not-usable-undetected.md) | resolved |
| DET002 | [BUG0043](bugs/closed/BUG0043-function-py-unbound-module-logger.md) | resolved |
| DET009 | [BUG0012](bugs/open/BUG0012-dev-detect-first-run-snapshot-vs-golden-template-n.md) | open |
| DET012 | [BUG0038](bugs/closed/BUG0038-dev-detect-reruns-every-boot.md) | resolved |
| DET013 | [BUG0038](bugs/closed/BUG0038-dev-detect-reruns-every-boot.md) | resolved |
| FUN005 | [BUG0013](bugs/open/BUG0013-log-entries-do-not-include-log-level-prefix.md) | open |
| FWK011 | [BUG0037](bugs/closed/BUG0037-net-test-local-unbound-var-kills-pair.md) | resolved |
| FWK013 | [BUG0038](bugs/closed/BUG0038-dev-detect-reruns-every-boot.md) | resolved |
| FWK013 | [BUG0041](bugs/closed/BUG0041-explicit-cycles-ignored-on-resume.md) | resolved |
| FWK013 | [BUG0046](bugs/open/BUG0046-calibrate-no-boot-power-down-race.md) | open |
| FWK025 | [BUG0014](bugs/closed/BUG0014-root-requirement-of-detection-scripts-not-formalis.md) | closed |
| FWK026 | [BUG0002](bugs/closed/BUG0002-cannot-open-dev-detect-sh-html-report.md) | closed |
| FWK026 | [BUG0014](bugs/closed/BUG0014-root-requirement-of-detection-scripts-not-formalis.md) | closed |
| FWK027 | [BUG0019](bugs/closed/BUG0019-result-json-metadata-corruption-session-id-unknown.md) | closed |
| FWK028 | [BUG0030](bugs/closed/BUG0030-os-detect-utf8-decode-crash.md) | resolved |
| FWK028 | [BUG0031](bugs/closed/BUG0031-os-probe-runs-before-power-on.md) | resolved |
| FWK028 | [BUG0035](bugs/closed/BUG0035-result-json-write-crash-loses-run.md) | resolved |
| FWK028 | [BUG0045](bugs/closed/BUG0045-report-shows-timeout-as-boot-time.md) | resolved |
| FWK028 | [BUG0048](bugs/closed/BUG0048-net-err-trap-false-positives.md) | resolved |
| FWK029 | [BUG0023](bugs/closed/BUG0023-log-dir-console-output.md) | resolved |
| FWK029 | [BUG0047](bugs/closed/BUG0047-net019-unmatched-mac-entry-silent.md) | resolved |
| FWK031 | [BUG0034](bugs/closed/BUG0034-reboot-os-probe-before-init-dut.md) | resolved |
| FWK031 | [BUG0036](bugs/open/BUG0036-reboot-slow-boot-misjudged-dead.md) | in-progress |
| FWK032 | [BUG0025](bugs/closed/BUG0025-power-cycle-msg-notification-not-shown.md) | resolved |
| FWK032 | [BUG0026](bugs/closed/BUG0026-dut-reboot-task-fires-during-python-tests.md) | closed |
| FWK032 | [BUG0040](bugs/closed/BUG0040-notify-dut-negative-sleep-traceback.md) | resolved |
| FWK032 | [BUG0049](bugs/closed/BUG0049-wall-broadcast-clobbers-progress-display.md) | resolved |
| FWK034 | [BUG0026](bugs/closed/BUG0026-dut-reboot-task-fires-during-python-tests.md) | closed |
| FWK035 | [BUG0033](bugs/closed/BUG0033-ssh-changed-host-key-blocks-all-cycles.md) | resolved |
| FWK035 | [BUG0034](bugs/closed/BUG0034-reboot-os-probe-before-init-dut.md) | resolved |
| FWK037 | [BUG0039](bugs/closed/BUG0039-dimm-populated-but-not-usable-undetected.md) | resolved |
| FWK037 | [BUG0043](bugs/closed/BUG0043-function-py-unbound-module-logger.md) | resolved |
| FWK038 | [BUG0050](bugs/closed/BUG0050-progress-bar-stops-before-step-does.md) | resolved |
| LOG001 | [BUG0023](bugs/closed/BUG0023-log-dir-console-output.md) | resolved |
| LOG001 | [BUG0042](bugs/closed/BUG0042-python-logs-follow-cwd.md) | resolved |
| LOG008 | [BUG0004](bugs/open/BUG0004-fio-log-filenames-missing-timestamp-and-result.md) | open |
| LOG012 | [BUG0024](bugs/closed/BUG0024-extract-bw-fails-on-slow-disks-no-data-0-0-mib-s-f.md) | closed |
| LOG012 | [BUG0004](bugs/open/BUG0004-fio-log-filenames-missing-timestamp-and-result.md) | open |
| LOG013 | [BUG0044](bugs/closed/BUG0044-calibrate-cycles-print-warmup-banner.md) | resolved |
| LOG013 | [BUG0049](bugs/closed/BUG0049-wall-broadcast-clobbers-progress-display.md) | resolved |
| LOG014 | [BUG0013](bugs/open/BUG0013-log-entries-do-not-include-log-level-prefix.md) | open |
| LOG015 | [BUG0001](bugs/closed/BUG0001-no-total-test-time.md) | closed |
| LOG015 | [BUG0009](bugs/closed/BUG0009-result-json-not-yet-implemented.md) | closed |
| LOG015 | [BUG0019](bugs/closed/BUG0019-result-json-metadata-corruption-session-id-unknown.md) | closed |
| LOG015 | [BUG0024](bugs/closed/BUG0024-extract-bw-fails-on-slow-disks-no-data-0-0-mib-s-f.md) | closed |
| LOG015 | [BUG0043](bugs/closed/BUG0043-function-py-unbound-module-logger.md) | resolved |
| LOG015 | [BUG0045](bugs/closed/BUG0045-report-shows-timeout-as-boot-time.md) | resolved |
| LOG015 | [BUG0048](bugs/closed/BUG0048-net-err-trap-false-positives.md) | resolved |
| LOG018 | [BUG0001](bugs/closed/BUG0001-no-total-test-time.md) | closed |
| LOG018 | [BUG0018](bugs/closed/BUG0018-html-report-total-test-time-computed-from-file-mti.md) | closed |
| LOG018 | [BUG0010](bugs/invalid/BUG0010-html-reports-may-be-parsing-log-instead-of-reading.md) | invalid |
| LOG020 | [BUG0019](bugs/closed/BUG0019-result-json-metadata-corruption-session-id-unknown.md) | closed |
| LOG021 | [BUG0002](bugs/closed/BUG0002-cannot-open-dev-detect-sh-html-report.md) | closed |
| LOG022 | [BUG0019](bugs/closed/BUG0019-result-json-metadata-corruption-session-id-unknown.md) | closed |
| LOG023 | [BUG0035](bugs/closed/BUG0035-result-json-write-crash-loses-run.md) | resolved |
| LOG023 | [BUG0041](bugs/closed/BUG0041-explicit-cycles-ignored-on-resume.md) | resolved |
| LOG025 | [BUG0041](bugs/closed/BUG0041-explicit-cycles-ignored-on-resume.md) | resolved |
| LOG025 | [BUG0042](bugs/closed/BUG0042-python-logs-follow-cwd.md) | resolved |
| LOG026 | [BUG0042](bugs/closed/BUG0042-python-logs-follow-cwd.md) | resolved |
| NET004 | [BUG0051](bugs/closed/BUG0051-ethtool-lane-count-parsed-as-speed.md) | resolved |
| NET006 | [BUG0029](bugs/closed/BUG0029-net-test-iperf3-firewall-rule-needs-elevation.md) | resolved |
| NET006 | [BUG0037](bugs/closed/BUG0037-net-test-local-unbound-var-kills-pair.md) | resolved |
| NET008 | [BUG0029](bugs/closed/BUG0029-net-test-iperf3-firewall-rule-needs-elevation.md) | resolved |
| NET008 | [BUG0048](bugs/closed/BUG0048-net-err-trap-false-positives.md) | resolved |
| NET009 | [BUG0029](bugs/closed/BUG0029-net-test-iperf3-firewall-rule-needs-elevation.md) | resolved |
| NET009 | [BUG0051](bugs/closed/BUG0051-ethtool-lane-count-parsed-as-speed.md) | resolved |
| NET011 | [BUG0015](bugs/open/BUG0015-net-test-sh-consumes-the-ssh-lifeline-nic.md) | open |
| NET012 | [BUG0047](bugs/closed/BUG0047-net019-unmatched-mac-entry-silent.md) | resolved |
| NET012 | [BUG0015](bugs/open/BUG0015-net-test-sh-consumes-the-ssh-lifeline-nic.md) | open |
| NET015 | [BUG0051](bugs/closed/BUG0051-ethtool-lane-count-parsed-as-speed.md) | resolved |
| NET015 | [BUG0052](bugs/closed/BUG0052-pair-max-speed-always-zero.md) | resolved |
| NET016 | [BUG0037](bugs/closed/BUG0037-net-test-local-unbound-var-kills-pair.md) | resolved |
| NET017 | [BUG0048](bugs/closed/BUG0048-net-err-trap-false-positives.md) | resolved |
| NET017 | [BUG0049](bugs/closed/BUG0049-wall-broadcast-clobbers-progress-display.md) | resolved |
| NET017 | [BUG0050](bugs/closed/BUG0050-progress-bar-stops-before-step-does.md) | resolved |
| NET019 | [BUG0047](bugs/closed/BUG0047-net019-unmatched-mac-entry-silent.md) | resolved |
| PWR004 | [BUG0046](bugs/open/BUG0046-calibrate-no-boot-power-down-race.md) | open |
| PWR009 | [BUG0025](bugs/closed/BUG0025-power-cycle-msg-notification-not-shown.md) | resolved |
| PWR009 | [BUG0033](bugs/closed/BUG0033-ssh-changed-host-key-blocks-all-cycles.md) | resolved |
| PWR011 | [BUG0025](bugs/closed/BUG0025-power-cycle-msg-notification-not-shown.md) | resolved |
| PWR011 | [BUG0026](bugs/closed/BUG0026-dut-reboot-task-fires-during-python-tests.md) | closed |
| PWR011 | [BUG0027](bugs/closed/BUG0027-reboot-py-boot-time-sec-measurement-defect.md) | resolved |
| PWR012 | [BUG0025](bugs/closed/BUG0025-power-cycle-msg-notification-not-shown.md) | resolved |
| PWR012 | [BUG0026](bugs/closed/BUG0026-dut-reboot-task-fires-during-python-tests.md) | closed |
| PWR012 | [BUG0027](bugs/closed/BUG0027-reboot-py-boot-time-sec-measurement-defect.md) | resolved |
| PWR012 | [BUG0032](bugs/closed/BUG0032-grub-menu-can-block-unattended-reboot-tests.md) | resolved |
| PWR012 | [BUG0033](bugs/closed/BUG0033-ssh-changed-host-key-blocks-all-cycles.md) | resolved |
| PWR012 | [BUG0034](bugs/closed/BUG0034-reboot-os-probe-before-init-dut.md) | resolved |
| PWR012 | [BUG0035](bugs/closed/BUG0035-result-json-write-crash-loses-run.md) | resolved |
| PWR012 | [BUG0040](bugs/closed/BUG0040-notify-dut-negative-sleep-traceback.md) | resolved |
| PWR012 | [BUG0041](bugs/closed/BUG0041-explicit-cycles-ignored-on-resume.md) | resolved |
| PWR012 | [BUG0036](bugs/open/BUG0036-reboot-slow-boot-misjudged-dead.md) | in-progress |
| PWR013 | [BUG0036](bugs/open/BUG0036-reboot-slow-boot-misjudged-dead.md) | in-progress |
| PWR016 | [BUG0044](bugs/closed/BUG0044-calibrate-cycles-print-warmup-banner.md) | resolved |
| PWR016 | [BUG0045](bugs/closed/BUG0045-report-shows-timeout-as-boot-time.md) | resolved |
| PWR016 | [BUG0046](bugs/open/BUG0046-calibrate-no-boot-power-down-race.md) | open |
| SET007 | [BUG0032](bugs/closed/BUG0032-grub-menu-can-block-unattended-reboot-tests.md) | resolved |
| SLP001 | [BUG0020](bugs/open/BUG0020-sleep-test-not-yet-integrated-or-verified.md) | open |
| SLP002 | [BUG0028](bugs/closed/BUG0028-sleep-test-detect-crashes-on-localized-windows.md) | resolved |
| SLP003 | [BUG0028](bugs/closed/BUG0028-sleep-test-detect-crashes-on-localized-windows.md) | resolved |
| SLP004 | [BUG0020](bugs/open/BUG0020-sleep-test-not-yet-integrated-or-verified.md) | open |
| SLP005 | [BUG0020](bugs/open/BUG0020-sleep-test-not-yet-integrated-or-verified.md) | open |

### Implemented Must-priority requirements with no associated bug

_(may indicate untested code paths — worth a review)_

| ID | Status | Title |
| --- | --- | --- |
| [DSK009](requirements/DSK009.md) | implemented | fio Engine and Write-Consistency Flags Aligned with KDiskMark v3.2.0 |
| [FUN007](requirements/FUN007.md) | implemented | Windows PowerShell Shared Function Library |
| [FWK002](requirements/FWK002.md) | implemented | Cross-Language Naming Conventions |
| [FWK030](requirements/FWK030.md) | implemented | Two-Phase Consecutive-Failure Stop Policy |
| [PWR001](requirements/PWR001.md) | implemented | AT and ATX PSU Type Selection |
| [PWR002](requirements/PWR002.md) | implemented | GPIO Relay Abstraction |
| [PWR003](requirements/PWR003.md) | implemented | Network-Based DUT Liveness Detection |
| [PWR005](requirements/PWR005.md) | implemented | Structured result.json Output (LOG015 Compliance) |
| [PWR007](requirements/PWR007.md) | implemented | Safety Controls: Consecutive Fail Abort and Graceful Stop |
| [PWR008](requirements/PWR008.md) | implemented | Power Cycle Test Warmup and Initial-State Normalization |
| [PWR010](requirements/PWR010.md) | implemented | Cycle Phase Timing Model and Parameter Defaults |
| [SET005](requirements/SET005.md) | implemented | Windows DUT Pre-test Bootstrap Script |
| [SET006](requirements/SET006.md) | implemented | Dual-Layer Configuration: config.py as Default Reference |

