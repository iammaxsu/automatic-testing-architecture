*** Settings ***
Documentation     Phase 1 IPMI - user accounts (`user list`). Read-only.
...               Listing only; user create/modify/delete is out of scope for
...               this read-only suite.
Resource          bmc.resource

*** Test Cases ***
User List Is Readable
    [Documentation]    `user list` returns a user table.
    [Tags]    user    smoke
    User List Should Be Readable    ${USER_CHANNEL}

Expected User Is Present
    [Documentation]    The expected account (e.g. admin) exists on the channel.
    [Tags]    user
    User Should Be Present    ${EXPECTED_USER}    ${USER_CHANNEL}
