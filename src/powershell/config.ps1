# Get the directory where the script is located
#$_scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition          # The directory for scripts 

# Define log directory path
#$_logPath = Join-Path $_scriptDir "logs"          # The path for logs directory   

# Create the log directory if it doesn't exist
#if (-not (Test-Path -Path $logPath)) {
#    New-Item -ItemType Directory -Path $logPath | Out-Null
#}

# Define variables
$_script_root   = Split-Path -Parent $MyInvocation.MyCommand.Definition     # the directory for scripts
$_logs_name     = 'logs'                         # folder name is 'logs'
$_log_path      = Join-Path $_script_root $_logs_name
$_counter = "counter.log"
$_date1 = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
$_date2 = Get-Date -Format 'yyyyMMddHHmmss'
$_golden = "dev_golden.log"
$_devGold = Get-Content "$_log_path\$_golden" -ErrorAction SilentlyContinue

# Output all variables to a text file
@"
`$_script_root=""$($_script_root)""
`$_logs_name=""$($_logs_name)""
`$_log_path=""$($_log_path)""
`$_counter=""$($_counter)""
`$_date1=""$($date1)""
`$_date2=""$($_date2)""
`$_golden=""$($_golden)""
"@ | Set-Content "$_log_path\config_vars.txt"
