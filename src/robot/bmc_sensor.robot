*** Settings ***
Documentation     Out-of-band BMC sensor functional + soak suite over IPMI.
...
...               Runs on the control node / any workstation that can reach
...               the BMC network interface (not on the DUT). Detection
...               semantics mirror src/bash-shell/bmc_sensor_test.sh:
...               baseline-relative, so sensors already non-ok at start
...               (e.g. unpopulated fan headers reading `nr`) do not fail -
...               only changes during the run do.
...
...               Required:
...               ${BMC_HOST}        -v BMC_HOST:10.0.0.124
...               IPMI_PASSWORD      environment variable (never a CLI arg)
...
...               Optional:
...               -v BMC_USER:admin   -v CYCLES:10   -v INTERVAL:5
...
...               Quick functional run:
...               export IPMI_PASSWORD='...'
...               robot -v BMC_HOST:10.0.0.124 -d logs/robot src/robot/bmc_sensor.robot
...
...               Weekend soak (~60 h):
...               robot -v BMC_HOST:10.0.0.124 -v CYCLES:3600 -v INTERVAL:60
...               ...   -d logs/robot src/robot/bmc_sensor.robot
...
...               Robot's report.html / log.html are the human-readable view;
...               canonical soak data lands in <outputdir>/bmc_sensor_soak_samples.csv
...               (FWK028).
Library           lib/BMCLibrary.py    host=${BMC_HOST}    user=${BMC_USER}
...               interface=${IPMI_IFACE}    timeout=${IPMI_TIMEOUT}
...               retries=${IPMI_RETRIES}    retry_delay=${IPMI_RETRY_DELAY}
Suite Setup       Run Keywords    Record Bmc Identity    AND    Establish Sensor Baseline

*** Variables ***
${BMC_HOST}           ${EMPTY}
${BMC_USER}           admin
${IPMI_IFACE}         lanplus
${IPMI_TIMEOUT}       60
${IPMI_RETRIES}       3
${IPMI_RETRY_DELAY}   5
${CYCLES}             10
${INTERVAL}           5
${MAX_COMM_FAIL_PCT}  1

*** Test Cases ***
BMC Responds To Sensor List
    [Documentation]    The BMC answers `sensor list` with at least one parsable sensor.
    ${sensors}=    Get Sensor Readings
    Should Not Be Empty    ${sensors}

Sensor Baseline Established
    [Documentation]    Suite setup captured a non-empty baseline (sensor set + status).
    ${count}=    Get Baseline Sensor Count
    Should Be True    ${count} > 0    baseline is empty

Sensor States Match Baseline
    [Documentation]    No sensor changed status, appeared, or disappeared since baseline.
    Sensor States Should Match Baseline

Sensor Soak
    [Documentation]    ${CYCLES} polls every ${INTERVAL}s. Fails on any status
    ...                transition or sensor-set change between consecutive
    ...                cycles, SEL growth over the soak window, or a comm
    ...                failure rate above ${MAX_COMM_FAIL_PCT}%. Canonical
    ...                samples: <outputdir>/bmc_sensor_soak_samples.csv.
    Run Sensor Soak    cycles=${CYCLES}    interval=${INTERVAL}
    ...                output_dir=${OUTPUT DIR}    max_comm_fail_pct=${MAX_COMM_FAIL_PCT}

SEL Entry Count Stable Across Suite
    [Documentation]    The SEL has exactly as many entries as at suite setup.
    Sel Entry Count Should Be Stable
