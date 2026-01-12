# scripts/build/build-component.ps1
# Build a single component using exploitation script

param(
    [Parameter(Mandatory=$true)]
    [string]$Script,
    
    [Parameter(Mandatory=$true)]
    [hashtable]$Params,
    
    [string]$ComponentName = "Unknown",
    [string]$ComponentType = "Unknown",
    [int]$TimeoutSeconds = 1800,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptName = "BUILD-COMPONENT"

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    Write-Output "[$ScriptName][$Level] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

Write-Log "INFO" "======================================================"
Write-Log "INFO" "BUILD COMPONENT: $ComponentName"
Write-Log "INFO" "======================================================"
Write-Log "INFO" "Script: $Script"
Write-Log "INFO" "Type: $ComponentType"
Write-Log "INFO" "Timeout: ${TimeoutSeconds}s"

$buildStart = Get-Date
$exitCode = 0

$result = @{
    name       = $ComponentName
    type       = $ComponentType
    script     = $Script
    status     = "PENDING"
    exitCode   = -1
    duration   = "00:00:00"
    command    = ""
    output     = ""
    error      = ""
    timedOut   = $false
}

try {
    # Validate script exists
    if (-not (Test-Path $Script)) {
        throw "Build script not found: $Script"
    }
    
    # Build command string
    $paramStrings = @()
    foreach ($key in $Params.Keys) {
        $value = $Params[$key]
        if ($value -is [bool]) {
            if ($value) { $paramStrings += "-$key" }
        }
        else {
            $paramStrings += "-$key `"$value`""
        }
    }
    
    $command = "& `"$Script`" $($paramStrings -join ' ')"
    $result.command = $command
    
    Write-Log "INFO" "Command: $command"
    Write-Log "INFO" "Parameters:"
    foreach ($key in $Params.Keys) {
        Write-Log "INFO" "  $key = $($Params[$key])"
    }
    
    if ($DryRun) {
        Write-Log "WARN" "[DRY RUN] Would execute command"
        $result.status = "SKIPPED"
        $result.exitCode = 0
        $result.output = "[DRY RUN] Command not executed"
    }
    else {
        Write-Log "INFO" "Executing build..."
        
        # Create temp files for output capture
        $tempStdout = [System.IO.Path]::GetTempFileName()
        $tempStderr = [System.IO.Path]::GetTempFileName()
        
        try {
            $processArgs = @(
                "-ExecutionPolicy", "Bypass",
                "-NoProfile",
                "-Command", $command
            )
            
            $process = Start-Process -FilePath "powershell.exe" `
                -ArgumentList $processArgs `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $tempStdout `
                -RedirectStandardError $tempStderr
            
            # Wait with timeout
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
            
            if (-not $completed) {
                Write-Log "ERROR" "Build timed out after ${TimeoutSeconds}s"
                $process.Kill()
                $result.timedOut = $true
                $result.status = "TIMEOUT"
                $result.exitCode = -1
                $exitCode = 1
            }
            else {
                $result.exitCode = $process.ExitCode
                
                if ($result.exitCode -eq 0) {
                    $result.status = "SUCCESS"
                    Write-Log "INFO" "Build completed successfully"
                }
                else {
                    $result.status = "FAILED"
                    Write-Log "ERROR" "Build failed with exit code: $($result.exitCode)"
                    $exitCode = 1
                }
            }
            
            # Capture output
            $result.output = Get-Content $tempStdout -Raw -ErrorAction SilentlyContinue
            $result.error = Get-Content $tempStderr -Raw -ErrorAction SilentlyContinue
            
            # Log output summary
            if ($result.output) {
                $outputLines = ($result.output -split "`n").Count
                Write-Log "INFO" "Stdout: $outputLines lines"
            }
            if ($result.error) {
                Write-Log "WARN" "Stderr captured"
            }
        }
        finally {
            Remove-Item $tempStdout -Force -ErrorAction SilentlyContinue
            Remove-Item $tempStderr -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    $result.status = "ERROR"
    $result.error = $_.Exception.Message
    Write-Log "ERROR" "Exception: $($_.Exception.Message)"
    $exitCode = 1
}

$result.duration = ((Get-Date) - $buildStart).ToString("hh\:mm\:ss")

Write-Log "INFO" "======================================================"
Write-Log "INFO" "RESULT: $($result.status)"
Write-Log "INFO" "Duration: $($result.duration)"
Write-Log "INFO" "Exit Code: $($result.exitCode)"
Write-Log "INFO" "======================================================"

# Output result as JSON for pipeline consumption
$result | ConvertTo-Json -Depth 5

exit $exitCode