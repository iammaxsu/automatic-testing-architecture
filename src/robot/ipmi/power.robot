*** Settings ***
Documentation     Phase 1 IPMI - chassis power CONTROL (DESTRUCTIVE, GATED).
...
...               These tests power the DUT off / cycle it, modelled on the
...               reliability runners power_cycle.py and reboot.py: perform the
...               action, verify recovery, measure the time.
...
...               SAFETY: every test is gated behind POWER_TESTS_ENABLED (via a
...               Test Setup) and tagged `power`, so a normal read-only run
...               SKIPS them and never disrupts the DUT. Enable deliberately:
...                 robot -v BMC_HOST:10.0.0.124 -v POWER_TESTS_ENABLED:True \
...                       -d logs/power src/robot/ipmi/power.robot
...
...               Recovery is confirmed by the BMC chassis power state. If you
...               also pass -v DUT_HOST:<dut-os-ip>, recovery additionally waits
...               for the DUT OS to answer ping (a real boot, like power_cycle.py).
...               Repeat count: -v POWER_CYCLES:<n>.
Resource          bmc.resource
Suite Setup       Record Bmc Identity
Test Setup        Require Power Tests Enabled
Test Tags         power

*** Test Cases ***
Power Off Then On Restores Power
    [Documentation]    Power the DUT off (verify off), then on (verify on, and
    ...                DUT liveness if DUT_HOST is set). Leaves the DUT powered on.
    Set Chassis Power    off
    ${off_secs}=    Wait For Chassis Power    off    timeout=${POWER_OFF_TIMEOUT}
    Log    DUT powered off in ${off_secs}s    console=True
    Set Chassis Power    on
    ${on_secs}=    Wait For Chassis Power    on    timeout=${POWER_ON_TIMEOUT}
    Log    chassis power back on in ${on_secs}s    console=True
    IF    '${DUT_HOST}' != ''
        ${boot_secs}=    Wait Until Host Alive    ${DUT_HOST}    ${DUT_BOOT_TIMEOUT}
        Log    DUT OS reachable ${boot_secs}s after power-on    console=True
    END

Power Cycle Restores Power
    [Documentation]    Power-cycle the DUT ${POWER_CYCLES} time(s); every cycle
    ...                must return to power on (and DUT liveness if DUT_HOST set).
    ...
    ...                RESUMABLE (LOG023/LOG026): progress is recorded in
    ...                ${LOG_ROOT}/<dut>/power_cycle_ipmi_session.json after every
    ...                cycle, so an interrupted run continues where it stopped.
    ...                Asking for a different POWER_CYCLES starts a NEW session
    ...                (you always get the count you asked for), and deleting the
    ...                logs tree resets everything. Force a fresh start with
    ...                -v NEW_SESSION:True.
    ${session}=    Start Or Resume Session    power_cycle_ipmi    ${POWER_CYCLES}
    ...    log_root=${LOG_ROOT}    new_session=${NEW_SESSION}
    ${target}=    Set Variable    ${session}[target]
    IF    ${session}[resuming]
        Log    resuming session ${session}[session_id]: ${session}[completed]/${target} done, ${session}[remaining] to go    console=True
    ELSE
        Log    new session ${session}[session_id]: ${target} cycle(s)    console=True
    END
    ${end}=    Evaluate    ${target} + 1
    FOR    ${n}    IN RANGE    ${session}[start_index]    ${end}
        Log    power cycle ${n}/${target}    console=True
        Set Chassis Power    cycle
        ${secs}=    Wait For Chassis Power    on    timeout=${POWER_ON_TIMEOUT}
        IF    '${DUT_HOST}' != ''
            Wait Until Host Alive    ${DUT_HOST}    ${DUT_BOOT_TIMEOUT}
        END
        Update Session Progress    ${n}
        Log    cycle ${n} recovered in ${secs}s    console=True
    END
    Complete Session
