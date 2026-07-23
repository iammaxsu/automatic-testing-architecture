*** Settings ***
Documentation     Phase 1 IPMI - FRU inventory (`fru print`). Read-only.
...               Identity checks are lenient because boards vary in which FRU
...               fields they populate.
Resource          bmc.resource

*** Test Cases ***
FRU Inventory Is Readable
    [Documentation]    `fru print 0` reads back with Board/Product fields.
    [Tags]    fru    smoke
    Fru Should Be Readable    0

FRU Reports Board Or Product Identity
    [Documentation]    At least one identity field (board/product mfg or name)
    ...                is populated.
    [Tags]    fru
    ${identity}=    Fru Should Have Identity    0
    Log    ${identity}
