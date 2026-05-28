### Functions 

$_script_root   = Split-Path -Parent $MyInvocation.MyCommand.Definition     # the directory for scripts
$_date1 = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
$_date2 = Get-Date -Format 'yyyyMMddHHmmss'

## Counter
. "$_script_root\config.ps1"         # This is the config file. MUST use the ABSOLUTE path for the task scheduler.

#${_counter} = "counter.log"         # Counter file
${_counter} = "$_script_root\logs\counter.log"         # Counter file

# Check the presence of counter file
if(!(Test-Path ${_counter})) {
    "" | Out-File ${_counter} -Encoding utf8
}

# Get the number from counter file
${_count} = Get-Content ${_counter} | ForEach-Object { $_.Trim() }

if ([string]::IsNullOrWhiteSpace(${_count}) -or ${_count} -eq "0") {
    ${_newcount} = 1
} elseif (${_count} -match '^\d+$') {
    ${_newcount} = [int]${_count} + 1
} else {
    ${_newcount} = 1                # If the content is not a number, reset to 1
}

# Update the number 
${_newcount} | Out-File ${_counter} -Encoding utf8

# Show the current count
Write-Host "${_newcount} cycles  ${_date1}  ${_date2} `n"
