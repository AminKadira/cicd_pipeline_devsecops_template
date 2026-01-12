#Requires -Version 7.0
<#
.SYNOPSIS
    Deploy a single component to a single server
.DESCRIPTION
    Wrapper for calling exploitation scripts with proper parameters
    Supports multiple script types (deployDotNetCore, deployWebAspDotNet)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$Script,

    [Parameter(Mandatory=$true)]
    [hashtable]$Params,

    [string]$Server,
    [string]$ComponentName,
    [string]$ReportsDir = "reports/deploy",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date

#region Logging
function Write-ComponentLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = "[$ComponentName][$Server]"
    
    $color = switch ($Level) {
        'ERROR'   { 'Red' }
        'WARN'    { 'Yellow' }
        'SUCCESS' { 'Green' }
        default   { 'White' }
    }
    
    Write-Host "[$timestamp] $prefix $Message" -ForegroundColor $color
}
#endregion

#region Main Execution
Write-Host ""
Write-Host ("─" * 50) -ForegroundColor DarkCyan
Write-Host " DEPLOY: $ComponentName → $Server" -ForegroundColor DarkCyan
Write-Host ("─" * 50) -ForegroundColor DarkCyan

$result = @{
    component = $ComponentName
    server = $Server
    script = $Script
    params = $Params
    status = "PENDING"
    exitCode = -1
    startTime = $script:StartTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    endTime = $null
    duration = $null
    output = ""
    error = ""
}

try {
    if ($DryRun) {
        Write-ComponentLog "[DRY-RUN] Would execute: $Script" -Level WARN
        Write-ComponentLog "[DRY-RUN] Parameters:" -Level WARN
        foreach ($key in $Params.Keys) {
            Write-ComponentLog "  -$key `"$($Params[$key])`"" -Level WARN
        }
        
        $result.status = "DRY-RUN"
        $result.exitCode = 0
        $result.output = "Dry run - no actual execution"
    }
    else {
        # Validate script exists
        if (-not (Test-Path $Script)) {
            throw "Deploy script not found: $Script"
        }
        
        Write-ComponentLog "Executing deploy script..."
        Write-ComponentLog "Script: $Script"
        
        # Build argument list
        $argList = @("-ExecutionPolicy", "Bypass", "-File", $Script)
        foreach ($key in $Params.Keys) {
            $argList += "-$key"
            $argList += "`"$($Params[$key])`""
        }
        
        # Create temp files for output capture
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        
        try {
            $processParams = @{
                FilePath = "powershell.exe"
                ArgumentList = $argList
                Wait = $true
                PassThru = $true
                NoNewWindow = $true
                RedirectStandardOutput = $stdoutFile
                RedirectStandardError = $stderrFile
            }
            
            $process = Start-Process @processParams
            $result.exitCode = $process.ExitCode
            
            # Capture output
            if (Test-Path $stdoutFile) {
                $result.output = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
            }
            if (Test-Path $stderrFile) {
                $result.error = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
            }
        }
        finally {
            Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        }
        
        if ($result.exitCode -eq 0) {
            $result.status = "SUCCESS"
            Write-ComponentLog "Deployment completed successfully" -Level SUCCESS
        }
        else {
            $result.status = "FAILED"
            Write-ComponentLog "Deployment failed (exit code: $($result.exitCode))" -Level ERROR
            if ($result.error) {
                Write-ComponentLog "Error: $($result.error.Substring(0, [Math]::Min(200, $result.error.Length)))" -Level ERROR
            }
        }
    }
}
catch {
    $result.status = "FAILED"
    $result.exitCode = 1
    $result.error = $_.Exception.Message
    Write-ComponentLog "Exception: $_" -Level ERROR
}

$result.endTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
$result.duration = ((Get-Date) - $script:StartTime).ToString("hh\:mm\:ss")

# Save component result
if (-not (Test-Path $ReportsDir)) {
    New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null
}

$resultFile = Join-Path $ReportsDir "deploy-$ComponentName-$Server-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$result | ConvertTo-Json -Depth 4 | Out-File -FilePath $resultFile -Encoding UTF8

Write-ComponentLog "Result saved: $resultFile"
Write-Host ""

# Return result for pipeline use
return $result

# Exit with appropriate code
exit $result.exitCode
#endregion