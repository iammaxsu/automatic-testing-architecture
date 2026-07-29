*** Settings ***
Documentation     Phase 1 IPMI - BMC LAN configuration (`lan print`). Read-only.
...               ${LAN_CHANNEL} is board-specific (often 1, sometimes 8); set
...               it in bmc.resource or via -v LAN_CHANNEL:<n>.
Resource          bmc.resource

*** Test Cases ***
BMC LAN Has IP Address
    [Documentation]    The BMC LAN channel reports a non-zero IPv4 address.
    [Tags]    lan    smoke
    Lan Should Have Ip Address    ${LAN_CHANNEL}

BMC LAN MAC Is Valid
    [Documentation]    The BMC LAN channel reports a valid, non-zero MAC.
    [Tags]    lan
    Lan Mac Should Be Valid    ${LAN_CHANNEL}
