*** Settings ***
Documentation     Evaluation spike (THROWAWAY): does the Kontron
...               robotframework-ipmilibrary connect to THIS BMC out of the box?
...
...               The library's two LAN connection keywords both go through
...               python-ipmi and default to IPMI 1.5:
...                 - Open Ipmi Rmcp Connection -> native 'rmcp' = IPMI 1.5
...                   (Get Session Challenge / Activate Session / MD5).
...                 - Open Ipmi Lan Connection  -> 'ipmitool' backend, which
...                   defaults to `-I lan` (IPMI 1.5); the keyword does not
...                   expose lanplus.
...               The connection keyword calls ipmi.open() immediately, so a
...               PASS means the session actually established. If your BMC
...               requires lanplus (IPMI 2.0) and disables 1.5, BOTH tests
...               here FAIL even though `ipmitool -I lanplus` works - that is
...               the signal that the RF library is not usable as-is, and the
...               engine decision falls to spike_probe.py Probe B.
...
...               Password comes from the IPMI_PASSWORD environment variable.
...               Run via run_spike.sh, or directly:
...                 robot -v BMC_HOST:10.0.0.124 -v BMC_USER:admin \
...                       -d <outdir> spike_ipmi.robot
Library           IpmiLibrary

*** Variables ***
${BMC_HOST}       ${EMPTY}
${BMC_USER}       admin
${TARGET_ADDR}    0x20
${PORT}           ${623}

*** Test Cases ***
RF Native RMCP Connection (IPMI 1.5)
    [Documentation]    Open Ipmi Rmcp Connection = python-ipmi native rmcp (1.5).
    ...                PASS => this BMC accepts IPMI 1.5 and the RF library is
    ...                usable as-is. FAIL (with ipmitool lanplus working) =>
    ...                BMC is lanplus-only; library not usable out of the box.
    [Teardown]    Run Keyword And Ignore Error    Close All Ipmi Connections
    Open Ipmi Rmcp Connection    ${BMC_HOST}    ${TARGET_ADDR}
    ...    user=${BMC_USER}    password=%{IPMI_PASSWORD}    port=${PORT}
    ${device_id}=    Get Bmc Device Id
    Log    ${device_id}    console=True

RF Lan Connection (ipmitool backend, IPMI 1.5)
    [Documentation]    Open Ipmi Lan Connection = ipmitool backend defaulting to
    ...                `-I lan` (1.5). Same pass/fail meaning as the native test.
    [Teardown]    Run Keyword And Ignore Error    Close All Ipmi Connections
    Open Ipmi Lan Connection    ${BMC_HOST}    ${TARGET_ADDR}
    ...    user=${BMC_USER}    password=%{IPMI_PASSWORD}    port=${PORT}
    ${device_id}=    Get Bmc Device Id
    Log    ${device_id}    console=True
