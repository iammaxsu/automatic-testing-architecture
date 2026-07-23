*** Settings ***
Documentation     Phase 1 IPMI - System Event Log (`sel info` / `sel elist`).
...               Read-only.
Resource          bmc.resource

*** Test Cases ***
SEL Is Readable
    [Documentation]    The System Event Log can be read (count + entry list).
    [Tags]    sel    smoke
    Sel Should Be Readable
    ${entries}=    Get Sel Entries
    Log    SEL entries: ${entries}
