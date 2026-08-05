*** Settings ***
Documentation     Phase 1 IPMI - chassis power CONTROL (DESTRUCTIVE, GATED).
...
...               These tests power the DUT off / cycle it, modelled on the
...               reliability runners power_cycle.py and reboot.py: perform the
...               action, verify recovery, measure the time. The cycle timing
...               follows PWR010 - notably the fixed OFF_TIME wait after the
...               board is off, before powering on again (BUG0028).
...
...               SAFETY: every test is gated behind POWER_TESTS_ENABLED (via a
...               Test Setup) and tagged `power`, so a normal read-only run
...               SKIPS them and never disrupts the DUT. Enable deliberately:
...                 robot -v BMC_HOST:10.0.0.124 -v POWER_TESTS_ENABLED:True \
...                       -d logs/power src/robot/ipmi/power.robot
...               The suite teardown leaves the DUT powered on even if a test
...               fails, so a failed run never leaves the machine dead.
...
...               Recovery is confirmed by the BMC chassis power state. If you
...               also pass -v DUT_HOST:<dut-os-ip>, recovery additionally waits
...               for the DUT OS to answer ping (a real boot, like power_cycle.py).
...               Repeat count: -v POWER_CYCLES:<n>.
Resource          bmc.resource
Suite Setup       Record Bmc Identity
Suite Teardown    Run Keyword If Any Tests Failed    Leave DUT Powered On
Test Setup        Require Power Tests Enabled
Test Tags         power

*** Keywords ***
Leave DUT Powered On
    [Documentation]    Safety net: never leave the DUT powered off after a
    ...                failed power test.
    ${state}=    Run Keyword And Ignore Error    Get Chassis Power State
    Run Keyword And Ignore Error    Ensure Chassis Power On
    ...    timeout=${POWER_ON_TIMEOUT}    reissue_after=${POWER_TRANSITION_TIMEOUT}

Confirm DUT Recovered
    [Documentation]    Chassis power is on; if DUT_HOST is set, the DUT OS is
    ...                reachable too (a real boot, not just power state).
    ${secs}=    Ensure Chassis Power On    timeout=${POWER_ON_TIMEOUT}
    ...    reissue_after=${POWER_TRANSITION_TIMEOUT}
    IF    '${DUT_HOST}' != ''
        ${boot}=    Wait Until Host Alive    ${DUT_HOST}    ${DUT_BOOT_TIMEOUT}
        Log    DUT OS reachable ${boot}s after power-on    console=True
    END
    RETURN    ${secs}

*** Test Cases ***
Power Off Then On Restores Power
    [Documentation]    Power the DUT off (verify off), wait the fixed OFF_TIME
    ...                (PWR010 phase 4), then power on and verify recovery.
    ...                Leaves the DUT powered on.
    Set Chassis Power    off
    ${off_secs}=    Wait For Chassis Power    off    timeout=${POWER_OFF_TIMEOUT}
    Log    DUT powered off in ${off_secs}s    console=True
    Log    waiting ${POWER_OFF_TIME}s off-time before power-on (PWR010)    console=True
    Sleep    ${POWER_OFF_TIME}
    ${on_secs}=    Confirm DUT Recovered
    Log    chassis power back on in ${on_secs}s    console=True

Power Cycle Restores Power
    [Documentation]    Power-cycle the DUT ${POWER_CYCLES} time(s); every cycle
    ...                must return to power on (and DUT liveness if DUT_HOST set).
    ...
    ...                `chassis power cycle` is only meaningful on a running
    ...                system, so the DUT is normalised to powered-on first.
    ...
    ...                RESUMABLE (LOG023/LOG026): progress is recorded in
    ...                ${LOG_ROOT}/<dut>/power_cycle_ipmi_session.json after every
    ...                cycle, so an interrupted run continues where it stopped.
    ...                Asking for a different POWER_CYCLES starts a NEW session
    ...                (you always get the count you asked for), and deleting the
    ...                logs tree resets everything. Force a fresh start with
    ...                -v NEW_SESSION:True.
    Ensure Chassis Power On    timeout=${POWER_ON_TIMEOUT}
    ...    reissue_after=${POWER_TRANSITION_TIMEOUT}
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
        # The board dips off then comes back. Missing the dip is fine (fast
        # boards, poll granularity) - recovery is what must hold.
        Run Keyword And Ignore Error    Wait For Chassis Power    off
        ...    timeout=${POWER_TRANSITION_TIMEOUT}
        ${secs}=    Confirm DUT Recovered
        Update Session Progress    ${n}
        Log    cycle ${n} recovered in ${secs}s    console=True
    END
    Complete Session
