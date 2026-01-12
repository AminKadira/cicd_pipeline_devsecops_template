#Requires -Version 7.0
<#
.SYNOPSIS
    Post-deployment health check with retry logic
.DESCRIPTION
    Validates application health by polling HTTP endpoint
    with configurable timeout and retry intervals
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerUrl,

    [string]$Endpoint = "/health",
    [int]$TimeoutSeconds = 120,
    [int]$RetryIntervalSeconds = 10,
    [int]$ExpectedStatus = 200,
    [string]$ExpectedContent,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

#region Logging
function Write-HealthLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    
    if ($Level -eq 'DEBUG' -and -not $Verbose) { return }
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $prefix = switch ($Level) {
        'INFO'    { "[INFO]  " }
        'WARN'    { "[WARN]  " }
        'ERROR'   { "[ERROR] " }
        'SUCCESS' { "[OK]    " }
        'DEBUG'   { "[DEBUG] " }
    }
    
    $color = switch ($Level) {
        'ERROR'   { 'Red' }
        'WARN'    { 'Yellow' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'Gray' }
        default   { 'White' }
    }
    
    Write-Host "[$timestamp] $prefix $Message" -ForegroundColor $color
}
#endregion

#region Health Check Logic
function Test-HealthEndpoint {
    param(
        [string]$Url,
        [int]$ExpectedStatus,
        [string]$ExpectedContent
    )
    
    $result = @{
        success = $false
        statusCode = 0
        responseTime = 0
        contentMatch = $null
        error = $null
    }
    
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        $response = Invoke-WebRequest -Uri $Url -Method GET -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        
        $stopwatch.Stop()
        $result.responseTime = $stopwatch.ElapsedMilliseconds
        $result.statusCode = $response.StatusCode
        
        # Check status code
        if ($response.StatusCode -ne $ExpectedStatus) {
            $result.error = "Status $($response.StatusCode) != expected $ExpectedStatus"
            return $result
        }
        
        # Check content if specified
        if ($ExpectedContent) {
            if ($response.Content -match $ExpectedContent) {
                $result.contentMatch = $true
            }
            else {
                $result.contentMatch = $false
                $result.error = "Content mismatch: pattern '$ExpectedContent' not found"
                return $result
            }
        }
        
        $result.success = $true
    }
    catch [System.Net.WebException] {
        $result.error = "Connection failed: $($_.Exception.Message)"
    }
    catch {
        $result.error = "Request error: $_"
    }
    
    return $result
}
#endregion

#region Main Execution
# Build full URL
$fullUrl = if ($ServerUrl -match '^https?://') {
    "$ServerUrl$Endpoint"
} else {
    "http://$ServerUrl$Endpoint"
}

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host " HEALTH CHECK" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host ""
Write-HealthLog "URL: $fullUrl"
Write-HealthLog "Timeout: ${TimeoutSeconds}s, Interval: ${RetryIntervalSeconds}s"
Write-HealthLog "Expected: HTTP $ExpectedStatus$(if ($ExpectedContent) { " + content match" })"
Write-Host ""

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$attemptNumber = 0
$attempts = @()

while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $attemptNumber++
    $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)
    
    Write-HealthLog "Attempt #$attemptNumber (${elapsed}s elapsed)..." -Level DEBUG
    
    $checkResult = Test-HealthEndpoint -Url $fullUrl -ExpectedStatus $ExpectedStatus -ExpectedContent $ExpectedContent
    
    $attempts += @{
        attempt = $attemptNumber
        elapsed = $elapsed
        statusCode = $checkResult.statusCode
        responseTime = $checkResult.responseTime
        success = $checkResult.success
        error = $checkResult.error
    }
    
    if ($checkResult.success) {
        Write-Host ""
        Write-Host ("=" * 50) -ForegroundColor Green
        Write-Host " HEALTH CHECK PASSED" -ForegroundColor Green
        Write-Host ("=" * 50) -ForegroundColor Green
        Write-Host ""
        Write-HealthLog "Status: $($checkResult.statusCode)" -Level SUCCESS
        Write-HealthLog "Response time: $($checkResult.responseTime)ms" -Level SUCCESS
        Write-HealthLog "Total time: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s ($attemptNumber attempts)"
        Write-Host ""
        
        return @{
            success = $true
            status = "PASS"
            url = $fullUrl
            statusCode = $checkResult.statusCode
            responseTime = $checkResult.responseTime
            totalDuration = $stopwatch.Elapsed.TotalSeconds
            attempts = $attemptNumber
            details = $attempts
        }
    }
    
    Write-HealthLog "Failed: $($checkResult.error)" -Level WARN
    
    # Wait before retry
    $remainingTime = $TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds
    $sleepTime = [math]::Min($RetryIntervalSeconds, $remainingTime)
    
    if ($sleepTime -gt 0) {
        Start-Sleep -Seconds $sleepTime
    }
}

# Timeout
Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Red
Write-Host " HEALTH CHECK FAILED" -ForegroundColor Red
Write-Host ("=" * 50) -ForegroundColor Red
Write-Host ""
Write-HealthLog "Timeout after $TimeoutSeconds seconds" -Level ERROR
Write-HealthLog "Attempts: $attemptNumber"
Write-HealthLog "Last error: $($attempts[-1].error)" -Level ERROR
Write-Host ""

return @{
    success = $false
    status = "FAIL"
    url = $fullUrl
    error = "Timeout after $TimeoutSeconds seconds"
    totalDuration = $stopwatch.Elapsed.TotalSeconds
    attempts = $attemptNumber
    details = $attempts
}
#endregionll