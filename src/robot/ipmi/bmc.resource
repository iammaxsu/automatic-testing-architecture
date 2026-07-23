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
