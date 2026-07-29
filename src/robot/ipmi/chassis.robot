*** Settings ***
Documentation     Phase 1 IPMI - chassis status (`chassis status`). Read-only.
...               Power *control* (on/off/cycle/reset) is deliberately NOT here;
...               it belongs in a separate, explicitly-gated suite.
Resource          bmc.resource

*** Test Cases ***
Chassis Power Is On
    [Documentation]    `chassis status` reports System Power = on (read-only).
    [Tags]    chassis
    Chassis Power Should Be On
