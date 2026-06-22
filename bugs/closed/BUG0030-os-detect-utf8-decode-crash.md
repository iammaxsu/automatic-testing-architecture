---
id: BUG0030
status: resolved
created: 2026-06-18
closed: 2026-06-18
os: [Windows 11 (zh-TW)]
related_requirements: [FWK028]
related_bugs: [BUG0031]
---

## Symptom

A power-cycle run against a Traditional-Chinese Windows DUT (10.0.0.146,
session `20260618T154225`) never used the SSH shutdown command. Every
cycle logged:

```
WARNING function: DUT OS detection failed: 'utf-8' codec can't decode byte
        0xa4 in position 918: invalid start byte — using config default
WARNING power_cycle: DUT OS not confirmed ... assuming 'linux' ...
...
WARNING shutdown: SSH shutdown command failed (exit 5): 此電腦上已停用 Sudo。
        若要啟用，請移至 [設定] 應用程式中的 Developer Settings page
WARNING shutdown: SSH shutdown failed — falling back to ATX press
```

The run still PASSed (the ATX power button cleanly shut Windows down),
but the intended graceful SSH shutdown never happened and the report
showed `OS: linux (assumed)` for a machine that is actually Windows.

## Root cause

`function.detect_dut_os()` runs `ssh user@host "uname -s"` and decoded the
result with `subprocess.run(..., text=True)`, which uses a strict UTF-8
decode. On a non-English Windows DUT, `uname` is not recognised and cmd.exe
emits its error in the OEM code page (CP950 / Big5), e.g. byte `0xa4` —
not valid UTF-8. The strict decode raised `UnicodeDecodeError`, the probe
returned `"unknown"`, and the caller fell back to `config.DUT_OS` ("linux")
with `dut_os_source = "assumed"`.

Because the OS was mis-assumed as linux, the shutdown coordinator selected
the **linux** command `sudo shutdown -h now` and sent it over SSH to a
Windows box. Windows 11's inbox `sudo.exe` is disabled by default, so the
command exited 5 ("Sudo is disabled on this computer"), SSH shutdown was
considered failed, and every cycle fell back to the ATX press.

So the chain was: non-UTF-8 probe output → decode crash → OS mis-assumed
as linux → wrong (sudo) shutdown command → SSH shutdown always fails →
ATX fallback. SSH connectivity and authentication were never the problem.

## Fix

Decode SSH/DUT output tolerantly with `errors="replace"` on every
`subprocess.run(..., text=True)` that reads DUT output in `function.py`
(`detect_dut_os`, `restore_dut_env`, `notify_dut`) and in
`shutdown.py:_try_ssh()`. With `errors="replace"`, `detect_dut_os` no
longer crashes: `uname -s` returns a non-zero exit on Windows, so the
probe correctly returns `"windows"`, the coordinator selects
`shutdown /s /t 5`, and the graceful SSH shutdown works.

## Verification

- `python3 -m py_compile function.py shutdown.py` passes.
- Re-run a power cycle against the zh-TW Windows DUT: the OS is detected as
  `windows` (no decode warning), the report header shows `OS: windows
  (detected)`, and the SSH shutdown method succeeds instead of falling back
  to ATX. Independent confirmation on hardware pending → status `resolved`.
