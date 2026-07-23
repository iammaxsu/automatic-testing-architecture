*** Settings ***
Documentation     Phase 1 IPMI - Management Controller identity (`mc info`).
...               Read-only.
Resource          bmc.resource

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
