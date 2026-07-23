*** Settings ***
Documentation     Phase 1 IPMI - sensor readings (`sensor list`). Read-only.
...               Sensor names are board-specific (see bmc.resource variables).
Resource          bmc.resource

*** Test Cases ***
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
    [Documentation]    The named voltage rail reads ok and within its band.
    [Tags]    sensor
    Sensor Status Should Be    ${SENSOR_VOLT}    ok
    Sensor Reading Should Be Between    ${SENSOR_VOLT}    ${VOLT_MIN}    ${VOLT_MAX}
