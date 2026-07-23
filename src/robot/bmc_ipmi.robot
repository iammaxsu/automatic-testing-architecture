*** Settings ***
Documentation     Phase 1 - BMC / IPMI 2.0 functional suite (out-of-band).
...
...               Read-only functional checks against a live DUT's BMC, run
...               from the control node (not the DUT). Engine: the ipmitool
...               CLI, wrapped by lib/BMCLibrary.py - chosen after the
...               src/robot/spike evaluation (python-ipmi / Kontron RF library
...               could not decode this BMC's responses). See docs/architecture.md.
...
...               Coverage vertical (device id -> sensor -> SEL -> chassis
...               power) is modelled on the openbmc-test-automation and Arm
...               SBMR-ACS IPMI suites. SAFETY: every test here is read-only.
...               Chassis power *control* (power off/cycle/reset) is
...               deliberately excluded so this suite is safe to run against a
...               DUT that is in use; power-control tests belong in a separate,
...               explicitly-gated suite.
...
...               Required:  -v BMC_HOST:10.0.0.124   and IPMI_PASSWORD env var
...               Optional:  -v BMC_USER:admin
...
...               Board-specific sensor names live in *** Variables *** below;
...               adjust ${SENSOR_TEMP} / ${SENSOR_VOLT} per DUT.
...
...               Run:
...                 export IPMI_PASSWORD='...'
...                 robot -v BMC_HOST:10.0.0.124 -d logs/ipmi src/robot/bmc_ipmi.robot
Library           lib/BMCLibrary.py    host=${BMC_HOST}    user=${BMC_USER}
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
# Board-specific sensor names (this DUT). Change per board.
${SENSOR_TEMP}        CPU_Temp
${SENSOR_VOLT}        5V_DUAL
${VOLT_MIN}           4.5
${VOLT_MAX}           5.5

*** Test Cases ***
BMC Is Reachable
    [Documentation]    The BMC answers `mc info` with a Device ID.
    [Tags]    device-id    smoke
    Bmc Should Be Reachable

BMC Reports IPMI 2.0
    [Documentation]    `mc info` reports IPMI version 2.0 (this DUT is driven lanplus).
    [Tags]    device-id
    Ipmi Version Should Be    2.0

Device ID Info Is Complete
    [Documentation]    mc info exposes the core identity fields.
    [Tags]    device-id
    ${info}=    Get Bmc Info
    Dictionary Should Contain Key    ${info}    Manufacturer ID
    Dictionary Should Contain Key    ${info}    Product ID
    Dictionary Should Contain Key    ${info}    Firmware Revision

Sensors Are Present And Readable
    [Documentation]    `sensor list` returns a non-empty, parsable set.
    [Tags]    sensor    smoke
    ${sensors}=    Get Sensor Readings
    Should Not Be Empty    ${sensors}

Temperature Sensor Is OK
    [Documentation]    The named temperature sensor exists and reads ok.
    [Tags]    sensor
    Sensor Should Be Present    ${SENSOR_TEMP}
    Sensor Status Should Be    ${SENSOR_TEMP}    ok

Voltage Rail Is In Range
    [Documentation]    The named voltage rail reads within its expected band.
    [Tags]    sensor
    Sensor Status Should Be    ${SENSOR_VOLT}    ok
    Sensor Reading Should Be Between    ${SENSOR_VOLT}    ${VOLT_MIN}    ${VOLT_MAX}

SEL Is Readable
    [Documentation]    The System Event Log can be read (count + entry list).
    [Tags]    sel    smoke
    Sel Should Be Readable
    ${entries}=    Get Sel Entries
    Log    SEL entries: ${entries}

Chassis Power Is On
    [Documentation]    `chassis status` reports System Power = on (read-only).
    [Tags]    chassis
    Chassis Power Should Be On
