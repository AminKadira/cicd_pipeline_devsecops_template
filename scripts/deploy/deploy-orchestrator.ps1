#Requires -Version 7.0
<#
.SYNOPSIS
    Deployment orchestrator - manages multi-component, multi-server deployments
.DESCRIPTION
    Orchestrates deployments using existing exploitation scripts (black box)
    Supports multiple deployment strategies and health checks
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Tst', 'Sta', 'Prd', 'tst', 'sta', 'prd')]
    [string]$Environment,

    [string]$ComponentFilter = "*",
    [string]$ServerFilter = "*",

    [ValidateSet("by-component", "by-server", "rolling")]
    [string]$Strategy = "by-component",

    [string]$ReportsDir = "reports/deploy",
    [switch]$DryRun,
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:DeploymentId = [guid]::NewGuid().ToString().Substring(0, 8)
$script:Deployments = @()

#region Logging
function Write-DeployLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        'INFO'    { "[INFO]   " }
        'WARN'    { "[WARN]   " }
        'ERROR'   { "[ERROR]  " }
        'SUCCESS' { "[OK]     " }
        'DEBUG'   { "[DEBUG]  " }
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

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-SubSection {
    param([string]$Title)
    Write-Host ""
    Write-Host ("─" * 50) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor DarkCyan
    Write-Host ("─" * 50) -ForegroundColor DarkCyan
}
#endregion

#region Variable Substitution
function Resolve-Variables {
    param(
        [string]$Template,
        [hashtable]$Variables
    )
    
    if (-not $Template) { return $Template }
    
    $result = $Template
    foreach ($key in $Variables.Keys) {
        $patterns = @(
            "`${$key}",
            "`$($key)",
            "%$key%"
        )
        foreach ($pattern in $patterns) {
            $result = $result.Replace($pattern, $Variables[$key])
        }
    }
    
    # Handle nested patterns like ${component.name}
    if ($result -match '\$\{([^}]+)\}') {
        foreach ($match in [regex]::Matches($result, '\$\{([^}]+)\}')) {
            $varName = $match.Groups[1].Value
            if ($Variables.ContainsKey($varName)) {
                $result = $result.Replace($match.Value, $Variables[$varName])
            }
        }
    }
    
    return $result
}
#endregion

#region Configuration Loading
function Get-DeploymentConfig {
    param([string]$Path)
    
    Write-DeployLog "Loading configuration: $Path"
    
    try {
        $config = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return $config
    }
    catch {
        throw "Failed to parse configuration: $_"
    }
}

function Resolve-TargetServers {
    param(
        [object]$Config,
        [string]$EnvName,
        [string]$Filter
    )
    
    $envNorm = (Get-Culture).TextInfo.ToTitleCase($EnvName.ToLower())
    $envConfig = $Config.project.environments | Where-Object { 
        $_.name -eq $envNorm -or $_.name.ToLower() -eq $EnvName.ToLower() 
    } | Select-Object -First 1
    
    if (-not $envConfig) {
        throw "Environment '$EnvName' not found in configuration"
    }
    
    $servers = @()
    if ($envConfig.targetServers) {
        $servers = $envConfig.targetServers | Where-Object { $_ -and $_.Trim() }
    }
    elseif ($envConfig.servers) {
        $servers = $envConfig.servers | Where-Object { $_ -and $_.Trim() }
    }
    
    if ($servers.Count -eq 0) {
        throw "No target servers configured for environment '$EnvName'"
    }
    
    # Apply filter
    if ($Filter -and $Filter -ne "*") {
        $servers = $servers | Where-Object { $_ -like $Filter }
    }
    
    Write-DeployLog "Resolved $($servers.Count) target server(s)"
    return $servers
}

function Get-DeployableComponents {
    param(
        [object]$Config,
        [string]$Filter
    )
    
    $components = @()
    
    # APIs from components.apis
    if ($Config.components.apis) {
        foreach ($api in $Config.components.apis) {
            $components += @{
                name = $api.name
                type = "apis"
                deployScript = $api.deployScript
                deployParams = $api.deployParams
            }
        }
    }
    
    # WebApps from components.webApps
    if ($Config.components.webApps) {
        foreach ($webapp in $Config.components.webApps) {
            $components += @{
                name = $webapp.name
                type = "webApps"
                deployScript = $webapp.deployScript
                deployParams = $webapp.deployParams
            }
        }
    }
    
    # Workers from components.workers
    if ($Config.components.workers) {
        foreach ($worker in $Config.components.workers) {
            $components += @{
                name = $worker.name
                type = "workers"
                deployScript = $worker.deployScript
                deployParams = $worker.deployParams
            }
        }
    }
    
    # Legacy: APIs from build.apis (fallback)
    if ($components.Count -eq 0 -and $Config.build.apis) {
        foreach ($api in $Config.build.apis) {
            $components += @{
                name = $api
                type = "apis"
                deployScript = "D:\_puppet\script\deployDotNetCore3.1.ps1"
                deployParams = @{ type = "Api"; baseFolder = "`${WORKSPACE}" }
            }
        }
    }
    
    # Apply filter
    if ($Filter -and $Filter -ne "*") {
        $components = $components | Where-Object { $_.name -like $Filter }
    }
    
    Write-DeployLog "Found $($components.Count) deployable component(s)"
    return $components
}
#endregion

#region Deployment Execution
function Build-DeployCommand {
    param(
        [hashtable]$Component,
        [string]$Server,
        [string]$Environment,
        [hashtable]$Variables
    )
    
    $script = $Component.deployScript
    $params = @{}
    
    # Detect script type and build appropriate parameters
    switch -Regex ($script) {
        "deployDotNetCore" {
            # deployDotNetCore3.1.ps1 parameters
            $params = @{
                server = $Server
                assemblyName = $Component.name
                type = $Component.deployParams.type ?? "Api"
                environment = $Environment
                baseFolder = Resolve-Variables ($Component.deployParams.baseFolder ?? "`${WORKSPACE}") $Variables
            }
        }
        "deployWebAspDotNet" {
            # deployWebAspDotNet.ps1 parameters
            $params = @{
                serverName = $Server
                environment = $Environment
                appName = $Component.name
                sourcePath = Resolve-Variables $Component.deployParams.sourcePath $Variables
                destPath = $Component.deployParams.destPath
            }
            if ($Component.deployParams.appPoolName) {
                $params.appPoolName = $Component.deployParams.appPoolName
            }
        }
        default {
            # Generic handling - pass all deployParams
            $params = @{ server = $Server; environment = $Environment }
            if ($Component.deployParams) {
                foreach ($key in $Component.deployParams.PSObject.Properties.Name) {
                    $params[$key] = Resolve-Variables $Component.deployParams.$key $Variables
                }
            }
        }
    }
    
    return @{
        Script = $script
        Params = $params
    }
}

function Invoke-ComponentDeploy {
    param(
        [hashtable]$Component,
        [string]$Server,
        [string]$Environment,
        [hashtable]$Variables,
        [switch]$DryRun
    )
    
    $result = @{
        component = $Component.name
        type = $Component.type
        server = $Server
        script = $Component.deployScript
        status = "PENDING"
        exitCode = -1
        startTime = Get-Date
        endTime = $null
        duration = $null
        message = ""
        healthCheck = $null
    }
    
    Write-DeployLog "Deploying $($Component.name) to $Server"
    
    # Build command
    $cmd = Build-DeployCommand -Component $Component -Server $Server -Environment $Environment -Variables $Variables
    
    if ($DryRun) {
        Write-DeployLog "[DRY-RUN] Script: $($cmd.Script)" -Level WARN
        Write-DeployLog "[DRY-RUN] Params: $($cmd.Params | ConvertTo-Json -Compress)" -Level WARN
        $result.status = "DRY-RUN"
        $result.exitCode = 0
        $result.message = "Dry run - no actual deployment"
        $result.endTime = Get-Date
        $result.duration = "00:00:00"
        return $result
    }
    
    # Validate script exists
    if (-not (Test-Path $cmd.Script)) {
        $result.status = "FAILED"
        $result.message = "Deploy script not found: $($cmd.Script)"
        Write-DeployLog $result.message -Level ERROR
        $result.endTime = Get-Date
        $result.duration = ((Get-Date) - $result.startTime).ToString("hh\:mm\:ss")
        return $result
    }
    
    try {
        # Build argument list
        $argList = @("-ExecutionPolicy", "Bypass", "-File", $cmd.Script)
        foreach ($key in $cmd.Params.Keys) {
            $argList += "-$key"
            $argList += $cmd.Params[$key]
        }
        
        Write-DeployLog "Executing: powershell.exe $($argList -join ' ')" -Level DEBUG
        
        $process = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $argList `
            -Wait -PassThru -NoNewWindow
        
        $result.exitCode = $process.ExitCode
        
        if ($result.exitCode -eq 0) {
            $result.status = "SUCCESS"
            $result.message = "Deployment successful"
            Write-DeployLog "Deployment to $Server completed" -Level SUCCESS
        }
        else {
            $result.status = "FAILED"
            $result.message = "Exit code: $($result.exitCode)"
            Write-DeployLog "Deployment failed: $($result.message)" -Level ERROR
        }
    }
    catch {
        $result.status = "FAILED"
        $result.exitCode = 1
        $result.message = "Exception: $_"
        Write-DeployLog $result.message -Level ERROR
    }
    
    $result.endTime = Get-Date
    $result.duration = ($result.endTime - $result.startTime).ToString("hh\:mm\:ss")
    
    return $result
}

function Invoke-HealthCheck {
    param(
        [string]$Server,
        [object]$Config,
        [int]$Timeout = 120
    )
    
    $port = $Config.tests.targetPort ?? $Config.healthCheck.port ?? "8080"
    $endpoint = $Config.tests.healthCheckEndpoint ?? $Config.healthCheck.endpoint ?? "/health"
    $url = "http://${Server}:${port}${endpoint}"
    
    Write-DeployLog "Health check: $url (timeout: ${Timeout}s)"
    
    $healthCheckScript = Join-Path $PSScriptRoot "health-check.ps1"
    
    if (Test-Path $healthCheckScript) {
        try {
            $hcResult = & $healthCheckScript -ServerUrl "http://${Server}:${port}" `
                -Endpoint $endpoint -TimeoutSeconds $Timeout -RetryIntervalSeconds 10
            return $hcResult
        }
        catch {
            Write-DeployLog "Health check script failed: $_" -Level ERROR
            return @{ success = $false; error = $_.Exception.Message }
        }
    }
    else {
        # Inline health check
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        while ($stopwatch.Elapsed.TotalSeconds -lt $Timeout) {
            try {
                $response = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    Write-DeployLog "Health check PASSED ($($response.StatusCode))" -Level SUCCESS
                    return @{
                        success = $true
                        status = "PASS"
                        responseTime = $stopwatch.ElapsedMilliseconds
                    }
                }
            }
            catch {
                Write-DeployLog "Health check attempt failed, retrying..." -Level DEBUG
            }
            Start-Sleep -Seconds 10
        }
        
        Write-DeployLog "Health check FAILED (timeout)" -Level ERROR
        return @{ success = $false; status = "FAIL"; error = "Timeout" }
    }
}
#endregion

#region Deployment Strategies
function Invoke-ByComponentStrategy {
    param(
        [array]$Components,
        [array]$Servers,
        [string]$Environment,
        [hashtable]$BaseVariables,
        [object]$Config,
        [switch]$DryRun,
        [switch]$SkipHealthCheck
    )
    
    Write-DeployLog "Strategy: BY-COMPONENT (each component to all servers)"
    
    $results = @()
    $componentIndex = 0
    
    foreach ($component in $Components) {
        $componentIndex++
        Write-SubSection "Component $componentIndex/$($Components.Count): $($component.name)"
        
        $serverIndex = 0
        foreach ($server in $Servers) {
            $serverIndex++
            Write-DeployLog "Server $serverIndex/$($Servers.Count): $server"
            
            $variables = $BaseVariables.Clone()
            $variables["server"] = $server
            $variables["component.name"] = $component.name
            
            $deployResult = Invoke-ComponentDeploy `
                -Component $component `
                -Server $server `
                -Environment $Environment `
                -Variables $variables `
                -DryRun:$DryRun
            
            # Health check if enabled and deploy succeeded
            if (-not $SkipHealthCheck -and $deployResult.status -eq "SUCCESS") {
                $hcResult = Invoke-HealthCheck -Server $server -Config $Config -Timeout 60
                $deployResult.healthCheck = @{
                    status = if ($hcResult.success) { "PASS" } else { "FAIL" }
                    responseTime = $hcResult.responseTime
                }
            }
            
            $results += $deployResult
        }
    }
    
    return $results
}

function Invoke-ByServerStrategy {
    param(
        [array]$Components,
        [array]$Servers,
        [string]$Environment,
        [hashtable]$BaseVariables,
        [object]$Config,
        [switch]$DryRun,
        [switch]$SkipHealthCheck
    )
    
    Write-DeployLog "Strategy: BY-SERVER (all components to each server)"
    
    $results = @()
    $serverIndex = 0
    
    foreach ($server in $Servers) {
        $serverIndex++
        Write-SubSection "Server $serverIndex/$($Servers.Count): $server"
        
        $componentIndex = 0
        foreach ($component in $Components) {
            $componentIndex++
            Write-DeployLog "Component $componentIndex/$($Components.Count): $($component.name)"
            
            $variables = $BaseVariables.Clone()
            $variables["server"] = $server
            $variables["component.name"] = $component.name
            
            $deployResult = Invoke-ComponentDeploy `
                -Component $component `
                -Server $server `
                -Environment $Environment `
                -Variables $variables `
                -DryRun:$DryRun
            
            $results += $deployResult
        }
        
        # Health check after all components on server
        if (-not $SkipHealthCheck) {
            $hcResult = Invoke-HealthCheck -Server $server -Config $Config -Timeout 60
            # Update last deployment result with health check
            if ($results.Count -gt 0) {
                $results[-1].healthCheck = @{
                    status = if ($hcResult.success) { "PASS" } else { "FAIL" }
                    responseTime = $hcResult.responseTime
                }
            }
        }
    }
    
    return $results
}

function Invoke-RollingStrategy {
    param(
        [array]$Components,
        [array]$Servers,
        [string]$Environment,
        [hashtable]$BaseVariables,
        [object]$Config,
        [switch]$DryRun,
        [switch]$SkipHealthCheck
    )
    
    Write-DeployLog "Strategy: ROLLING (one server at a time with health check gate)"
    
    $results = @()
    $serverIndex = 0
    
    foreach ($server in $Servers) {
        $serverIndex++
        Write-SubSection "Rolling Deploy $serverIndex/$($Servers.Count): $server"
        
        $serverSuccess = $true
        
        foreach ($component in $Components) {
            $variables = $BaseVariables.Clone()
            $variables["server"] = $server
            $variables["component.name"] = $component.name
            
            $deployResult = Invoke-ComponentDeploy `
                -Component $component `
                -Server $server `
                -Environment $Environment `
                -Variables $variables `
                -DryRun:$DryRun
            
            $results += $deployResult
            
            if ($deployResult.status -ne "SUCCESS" -and $deployResult.status -ne "DRY-RUN") {
                $serverSuccess = $false
                break
            }
        }
        
        # Mandatory health check between servers in rolling strategy
        if ($serverSuccess -and -not $DryRun) {
            Write-DeployLog "Running mandatory health check before next server..."
            $hcResult = Invoke-HealthCheck -Server $server -Config $Config -Timeout 120
            
            if (-not $hcResult.success) {
                Write-DeployLog "Health check FAILED - STOPPING rolling deployment" -Level ERROR
                $results[-1].healthCheck = @{ status = "FAIL"; error = $hcResult.error }
                break
            }
            
            $results[-1].healthCheck = @{
                status = "PASS"
                responseTime = $hcResult.responseTime
            }
            Write-DeployLog "Server $server healthy - proceeding to next" -Level SUCCESS
        }
    }
    
    return $results
}
#endregion

#region Report Generation
function New-DeploymentReport {
    param(
        [array]$Results,
        [string]$Environment,
        [string]$Strategy,
        [array]$Servers,
        [string]$ProjectName,
        [string]$ReportDir
    )
    
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    }
    
    $endTime = Get-Date
    $duration = ($endTime - $script:StartTime).ToString("hh\:mm\:ss")
    
    $successCount = ($Results | Where-Object { $_.status -eq "SUCCESS" -or $_.status -eq "DRY-RUN" }).Count
    $failedCount = ($Results | Where-Object { $_.status -eq "FAILED" }).Count
    $hcPassedCount = ($Results | Where-Object { $_.healthCheck.status -eq "PASS" }).Count
    
    $report = @{
        timestamp = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
        deploymentId = $script:DeploymentId
        project = $ProjectName
        environment = $Environment
        strategy = $Strategy
        duration = $duration
        servers = $Servers
        deployments = $Results
        summary = @{
            totalDeployments = $Results.Count
            success = $successCount
            failed = $failedCount
            healthChecksPassed = $hcPassedCount
        }
    }
    
    $reportPath = Join-Path $ReportDir "deploy-report-$($script:DeploymentId).json"
    $report | ConvertTo-Json -Depth 8 | Out-File -FilePath $reportPath -Encoding UTF8
    
    # Latest symlink
    $latestPath = Join-Path $ReportDir "deploy-report-latest.json"
    Copy-Item -Path $reportPath -Destination $latestPath -Force
    
    Write-DeployLog "Report: $reportPath"
    
    return $report
}
#endregion

#region Main Execution
Write-Section "DEPLOYMENT ORCHESTRATOR"
Write-Host ""
Write-DeployLog "Deployment ID: $script:DeploymentId"
Write-DeployLog "Config: $ConfigPath"
Write-DeployLog "Environment: $Environment"
Write-DeployLog "Strategy: $Strategy"
Write-DeployLog "Component Filter: $ComponentFilter"
Write-DeployLog "Server Filter: $ServerFilter"
if ($DryRun) { Write-DeployLog "MODE: DRY RUN" -Level WARN }
if ($SkipHealthCheck) { Write-DeployLog "Health Check: DISABLED" -Level WARN }

try {
    # Load configuration
    $config = Get-DeploymentConfig -Path $ConfigPath
    $projectName = $config.project.name ?? "unknown"
    
    # Normalize environment
    $envNorm = (Get-Culture).TextInfo.ToTitleCase($Environment.ToLower())
    
    # Resolve servers
    $servers = Resolve-TargetServers -Config $config -EnvName $Environment -Filter $ServerFilter
    Write-DeployLog "Target servers: $($servers -join ', ')"
    
    # Get components
    $components = Get-DeployableComponents -Config $config -Filter $ComponentFilter
    
    if ($components.Count -eq 0) {
        throw "No deployable components found matching filter '$ComponentFilter'"
    }
    
    Write-DeployLog "Components to deploy:"
    foreach ($comp in $components) {
        Write-DeployLog "  - $($comp.name) ($($comp.type))"
    }
    
    # Base variables
    $baseVariables = @{
        "WORKSPACE" = $env:WORKSPACE ?? (Get-Location).Path
        "environment" = $envNorm
    }
    
    # Execute deployment strategy
    Write-Section "EXECUTING DEPLOYMENT"
    
    $results = switch ($Strategy) {
        "by-component" {
            Invoke-ByComponentStrategy `
                -Components $components `
                -Servers $servers `
                -Environment $envNorm `
                -BaseVariables $baseVariables `
                -Config $config `
                -DryRun:$DryRun `
                -SkipHealthCheck:$SkipHealthCheck
        }
        "by-server" {
            Invoke-ByServerStrategy `
                -Components $components `
                -Servers $servers `
                -Environment $envNorm `
                -BaseVariables $baseVariables `
                -Config $config `
                -DryRun:$DryRun `
                -SkipHealthCheck:$SkipHealthCheck
        }
        "rolling" {
            Invoke-RollingStrategy `
                -Components $components `
                -Servers $servers `
                -Environment $envNorm `
                -BaseVariables $baseVariables `
                -Config $config `
                -DryRun:$DryRun `
                -SkipHealthCheck:$SkipHealthCheck
        }
    }
    
    # Generate report
    Write-Section "DEPLOYMENT SUMMARY"
    
    $report = New-DeploymentReport `
        -Results $results `
        -Environment $envNorm `
        -Strategy $Strategy `
        -Servers $servers `
        -ProjectName $projectName `
        -ReportDir $ReportsDir
    
    # Display summary
    Write-Host ""
    $successRate = if ($report.summary.totalDeployments -gt 0) {
        [math]::Round(($report.summary.success / $report.summary.totalDeployments) * 100, 1)
    } else { 0 }
    
    $summaryColor = if ($report.summary.failed -eq 0) { 'Green' } else { 'Red' }
    
    Write-Host ("=" * 70) -ForegroundColor $summaryColor
    if ($report.summary.failed -eq 0) {
        Write-Host " DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
    } else {
        Write-Host " DEPLOYMENT COMPLETED WITH FAILURES" -ForegroundColor Red
    }
    Write-Host ("=" * 70) -ForegroundColor $summaryColor
    Write-Host ""
    Write-Host "Project:       $projectName"
    Write-Host "Environment:   $envNorm"
    Write-Host "Strategy:      $Strategy"
    Write-Host "Duration:      $($report.duration)"
    Write-Host ""
    Write-Host "Deployments:   $($report.summary.success)/$($report.summary.totalDeployments) successful ($successRate%)"
    Write-Host "Health Checks: $($report.summary.healthChecksPassed) passed"
    Write-Host ""
    Write-Host "Report: $ReportsDir/deploy-report-$($script:DeploymentId).json"
    Write-Host ""
    
    exit $(if ($report.summary.failed -eq 0) { 0 } else { 1 })
}
catch {
    Write-DeployLog "FATAL ERROR: $_" -Level ERROR
    Write-DeployLog $_.ScriptStackTrace -Level DEBUG
    exit 1
}
#endregion