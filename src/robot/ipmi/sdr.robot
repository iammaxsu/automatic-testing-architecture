*** Settings ***
Documentation     Phase 1 IPMI - SDR repository (`sdr info`). Read-only.
Resource          bmc.resource

*** Test Cases ***
SDR Repository Is Readable
    [Documentation]    `sdr info` returns the repository info block.
    [Tags]    sdr    smoke
    ${info}=    Get Sdr Repository Info
    Log    ${info}

SDR Repository Is Populated
    [Documentation]    The SDR repository holds at least one record.
    [Tags]    sdr
    ${count}=    Sdr Repository Should Be Populated
    Log    SDR records: ${count}
