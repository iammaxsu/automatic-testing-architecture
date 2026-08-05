*** Settings ***
Documentation     Shared configuration for the Phase 1 BMC / IPMI 2.0
...               functional suites (out-of-band, run from the control node).
...
...               Engine: the ipmitool CLI wrapped by lib/BMCLibrary.py,
...               chosen after the evaluation spike (ADR-0001, docs/architecture.md).
...               Every suite that imports this resource is read-only and safe
...               to run against a live DUT; there is no power control here.
...
...               Board-specific expected values (sensor names, LAN channel,
...               expected user) live in *** Variables *** below - adjust per DUT.
Library           ../lib/BMCLibrary.py    host=${BMC_HOST}    user=${BMC_USER}
...               interface=${IPMI_IFACE}    timeout=${IPMI_TIMEOUT}
...               retries=${IPMI_RETRIES}    retry_delay=${IPMI_RETRY_DELAY}
Library           Collections

*** Variables ***
${BMC_HOST}           ${EMPTY}
${BMC_USER}           admin
${IPMI_IFACE}         lanplus
${IPMI_TIMEOUT}       60
${IPMI_RETRIES}       3
${IPMI_RETRY_DELAY}   5
# Board-specific expectations for this DUT. Change per board.
${SENSOR_TEMP}        CPU_Temp
${SENSOR_VOLT}        5V_DUAL
${VOLT_MIN}           4.5
${VOLT_MAX}           5.5
${LAN_CHANNEL}        1
${USER_CHANNEL}       1
${EXPECTED_USER}      admin
# Power-control suite (power.robot) - DESTRUCTIVE, gated off by default.
${POWER_TESTS_ENABLED}    ${FALSE}
${POWER_CYCLES}           1
${POWER_OFF_TIMEOUT}      60
${POWER_ON_TIMEOUT}       180
# Fixed wait after the board is off, before powering on again. PWR010 phase 4
# (OFF_TIME_SEC, config.py default 60): boards need real off-time or the
# power-on command is swallowed (BUG0028).
${POWER_OFF_TIME}         60
# Upper limit for observing the brief off dip after a `chassis power cycle`.
${POWER_TRANSITION_TIMEOUT}    30
${DUT_HOST}               ${EMPTY}
${DUT_BOOT_TIMEOUT}       300
# Session / resume (LOG023, LOG026). State lives at
# <LOG_ROOT>/<dut>/<test>_session.json - delete the logs tree for a full reset.
${LOG_ROOT}               logs
${NEW_SESSION}            ${FALSE}

*** Keywords ***
Require Power Tests Enabled
    [Documentation]    Skip the calling test unless power tests are explicitly
    ...                enabled. Guards the destructive power-control suite so a
    ...                normal read-only run can never power-cycle the DUT.
    Skip If    '${POWER_TESTS_ENABLED}'.lower() not in ('true', '1', 'yes', 'on')
    ...    Power-control tests are gated (they power-cycle the DUT). Enable with -v POWER_TESTS_ENABLED:True
