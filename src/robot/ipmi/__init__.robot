*** Settings ***
Documentation     Phase 1 BMC / IPMI 2.0 functional suites (out-of-band).
...
...               Read-only by default; the power-control suite (power.robot)
...               is gated off unless POWER_TESTS_ENABLED is set.
...
...               The directory suite setup records the BMC identity (host,
...               firmware revision, IPMI version, manufacturer, product) as
...               report metadata, so every report states which BMC/firmware
...               was under test.
Resource          bmc.resource
Suite Setup       Run Keywords    Ipmi Credentials Should Be Configured
...               AND    Record Bmc Identity
