# scripts/build/build-orchestrator.ps1
# Orchestrates build execution across all component types using exploitation scripts

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("Tst","Sta","Prd")]
    [string]$Environment,
    
    [string]$GlobalConfigPath = "config/global.json",
    [string]$ComponentFilter = "*",
    [string]$ComponentTypeFilter = "*",
    [string]$ReportDir = "reports/build",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptName = "BUILD-ORCHESTRATOR"

#region Logging
function Write-Log {
    param(
        [string]$Level = "INFO",
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $output = "[$ScriptName][$Level] $timestamp - $Message"
    
    switch ($Level) {
        "ERROR" { Write-Host $output -ForegroundColor Red }
        "WARN"  { Write-Host $output -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $output -ForegroundColor Green }
        default { Write-Host $output }
    }
}
#endregion

#region Variable Resolution
function Resolve-Variables {
    param(
        [string]$Template,
        [hashtable]$Variables
    )
    
    if ([string]::IsNullOrEmpty($Template)) { return $Template }
    
    $result = $Template
    foreach ($key in $Variables.Keys) {
        $pattern = "\`$\{$key\}"
        $result = $result -replace $pattern, $Variables[$key]
    }
    
    # Also support $env:VAR syntax
    $result = [Environment]::ExpandEnvironmentVariables($result)
    
    return $result
}

function Build-VariableContext {
    param(
        [string]$Environment,
        [PSCustomObject]$Component,
        [string]$ComponentType
    )
    
    return @{
        "WORKSPACE"       = $env:WORKSPACE ?? $PWD.Path
        "environment"     = $Environment
        "Environment"     = $Environment
        "ENV"             = $Environment.ToUpper()
        "component.name"  = $Component.name
        "component.type"  = $ComponentType
        "baseFolder"      = $env:WORKSPACE ?? $PWD.Path
    }
}
#endregion

#region Command Building
function Build-CommandParams {
    param(
        [PSCustomObject]$Component,
        [PSCustomObject]$GlobalConfig,
        [string]$Environment,
        [hashtable]$Variables
    )
    
    $params = @{}
    
    # Add params from component config
    if ($Component.params) {
        $Component.params.PSObject.Properties | ForEach-Object {
            $value = Resolve-Variables -Template $_.Value -Variables $Variables
            $params[$_.Name] = $value
        }
    }
    
    # Add proxy from global config if not overridden
    if ($GlobalConfig.proxy -and -not $params.ContainsKey("proxyServer")) {
        $params["proxyServer"] = $GlobalConfig.proxy.server
        $params["proxyPort"] = $GlobalConfig.proxy.port
    }
    
    # Ensure environment is set
    if (-not $params.ContainsKey("environment")) {
        $params["environment"] = $Environment
    }
    
    return $params
}

function Build-CommandString {
    param(
        [string]$ScriptPath,
        [hashtable]$Params
    )
    
    $paramStrings = @()
    foreach ($key in $Params.Keys) {
        $value = $Params[$key]
        if ($value -is [bool]) {
            if ($value) { $paramStrings += "-$key" }
        }
        elseif ($value -is [array]) {
            $paramStrings += "-$key `"$($value -join ',')`""
        }
        else {
            $paramStrings += "-$key `"$value`""
        }
    }
    
    return "& `"$ScriptPath`" $($paramStrings -join ' ')"
}
#endregion

#region Component Execution
function Invoke-ComponentBuild {
    param(
        [PSCustomObject]$Component,
        [string]$ComponentType,
        [PSCustomObject]$GlobalConfig,
        [string]$Environment,
        [switch]$DryRun
    )
    
    $componentStart = Get-Date
    $result = @{
        name      = $Component.name
        type      = $ComponentType
        script    = $Component.script
        status    = "PENDING"
        exitCode  = -1
        duration  = "00:00:00"
        command   = ""
        output    = ""
        error     = ""
    }
    
    try {
        # Build variable context
        $variables = Build-VariableContext -Environment $Environment -Component $Component -ComponentType $ComponentType
        
        # Resolve script path
        $scriptPath = Resolve-Variables -Template $Component.script -Variables $variables
        $result.script = $scriptPath
        
        # Validate script exists
        if (-not (Test-Path $scriptPath)) {
            throw "Build script not found: $scriptPath"
        }
        
        # Build parameters
        $params = Build-CommandParams -Component $Component -GlobalConfig $GlobalConfig -Environment $Environment -Variables $variables
        
        # Build command string
        $command = Build-CommandString -ScriptPath $scriptPath -Params $params
        $result.command = $command
        
        Write-Log "INFO" "Executing: $($Component.name)"
        Write-Log "INFO" "Command: $command"
        
        if ($DryRun) {
            Write-Log "WARN" "[DRY RUN] Would execute: $command"
            $result.status = "SKIPPED"
            $result.exitCode = 0
            $result.output = "[DRY RUN] Command not executed"
        }
        else {
            # Execute build script
            $tempStdout = [System.IO.Path]::GetTempFileName()
            $tempStderr = [System.IO.Path]::GetTempFileName()
            
            try {
                $process = Start-Process -FilePath "powershell.exe" `
                    -ArgumentList @("-ExecutionPolicy", "Bypass", "-Command", $command) `
                    -NoNewWindow -Wait -PassThru `
                    -RedirectStandardOutput $tempStdout `
                    -RedirectStandardError $tempStderr
                
                $result.exitCode = $process.ExitCode
                $result.output = Get-Content $tempStdout -Raw -ErrorAction SilentlyContinue
                $result.error = Get-Content $tempStderr -Raw -ErrorAction SilentlyContinue
                
                if ($result.exitCode -eq 0) {
                    $result.status = "SUCCESS"
                    Write-Log "SUCCESS" "$($Component.name) built successfully"
                }
                else {
                    $result.status = "FAILED"
                    Write-Log "ERROR" "$($Component.name) failed with exit code $($result.exitCode)"
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
        Write-Log "ERROR" "Exception building $($Component.name): $($_.Exception.Message)"
    }
    
    $result.duration = ((Get-Date) - $componentStart).ToString("hh\:mm\:ss")
    return $result
}
#endregion

#region Main Execution
Write-Log "INFO" "======================================================"
Write-Log "INFO" "BUILD ORCHESTRATOR"
Write-Log "INFO" "======================================================"
Write-Log "INFO" "Config: $ConfigPath"
Write-Log "INFO" "Environment: $Environment"
Write-Log "INFO" "Component Filter: $ComponentFilter"
Write-Log "INFO" "Type Filter: $ComponentTypeFilter"
if ($DryRun) { Write-Log "WARN" "DRY RUN MODE - No builds will be executed" }
Write-Log "INFO" "======================================================"

$orchestratorStart = Get-Date
$buildResults = @()
$exitCode = 0

try {
    # Load project configuration
    if (-not (Test-Path $ConfigPath)) {
        throw "Project configuration not found: $ConfigPath"
    }
    $projectConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $projectName = $projectConfig.project.name
    
    Write-Log "INFO" "Project: $projectName"
    
    # Load global configuration
    $globalConfig = $null
    if (Test-Path $GlobalConfigPath) {
        $globalConfig = Get-Content $GlobalConfigPath -Raw | ConvertFrom-Json
        Write-Log "INFO" "Global config loaded: $GlobalConfigPath"
    }
    else {
        Write-Log "WARN" "Global config not found, using defaults"
        $globalConfig = [PSCustomObject]@{
            proxy = [PSCustomObject]@{
                server = "proxy.fr.pluxee.tools"
                port = "3128"
            }
        }
    }
    
    # Ensure report directory
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    
    # Define execution order
    $componentTypes = @("apis", "webApps", "consoleServices", "batches", "workers")
    
    # Filter types if specified
    if ($ComponentTypeFilter -ne "*") {
        $componentTypes = $componentTypes | Where-Object { $_ -like $ComponentTypeFilter }
    }
    
    Write-Log "INFO" "Component types to process: $($componentTypes -join ', ')"
    Write-Log "INFO" ""
    
    # Process each component type
    foreach ($componentType in $componentTypes) {
        $components = $projectConfig.build.$componentType
        
        if (-not $components -or $components.Count -eq 0) {
            Write-Log "INFO" "No $componentType defined in configuration"
            continue
        }
        
        Write-Log "INFO" "======================================================"
        Write-Log "INFO" "Processing: $componentType ($($components.Count) components)"
        Write-Log "INFO" "======================================================"
        
        $typeIndex = 0
        foreach ($component in $components) {
            $typeIndex++
            
            # Check if component is enabled
            if ($component.PSObject.Properties["enabled"] -and -not $component.enabled) {
                Write-Log "WARN" "[$typeIndex/$($components.Count)] $($component.name) - SKIPPED (disabled)"
                $buildResults += @{
                    name     = $component.name
                    type     = $componentType
                    status   = "SKIPPED"
                    exitCode = 0
                    duration = "00:00:00"
                    command  = ""
                    output   = "Component disabled in configuration"
                }
                continue
            }
            
            # Apply component filter
            if ($ComponentFilter -ne "*" -and $component.name -notlike $ComponentFilter) {
                Write-Log "INFO" "[$typeIndex/$($components.Count)] $($component.name) - SKIPPED (filter)"
                continue
            }
            
            Write-Log "INFO" ""
            Write-Log "INFO" "------------------------------------------------------"
            Write-Log "INFO" "[$typeIndex/$($components.Count)] Building: $($component.name)"
            Write-Log "INFO" "------------------------------------------------------"
            
            $result = Invoke-ComponentBuild `
                -Component $component `
                -ComponentType $componentType `
                -GlobalConfig $globalConfig `
                -Environment $Environment `
                -DryRun:$DryRun
            
            $buildResults += $result
            
            # Track failures
            if ($result.status -eq "FAILED" -or $result.status -eq "ERROR") {
                $exitCode = 1
                
                # Check if we should stop on failure
                if ($component.PSObject.Properties["stopOnFailure"] -and $component.stopOnFailure) {
                    Write-Log "ERROR" "Stopping orchestration due to stopOnFailure flag"
                    break
                }
            }
        }
    }
    
    # Generate summary
    $successCount = ($buildResults | Where-Object { $_.status -eq "SUCCESS" }).Count
    $failedCount = ($buildResults | Where-Object { $_.status -in @("FAILED", "ERROR") }).Count
    $skippedCount = ($buildResults | Where-Object { $_.status -eq "SKIPPED" }).Count
    
    $totalDuration = (Get-Date) - $orchestratorStart
    
    # Build report
    $report = @{
        timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        project     = $projectName
        environment = $Environment
        dryRun      = $DryRun.IsPresent
        duration    = $totalDuration.ToString("hh\:mm\:ss")
        components  = $buildResults
        summary     = @{
            total   = $buildResults.Count
            success = $successCount
            failed  = $failedCount
            skipped = $skippedCount
        }
    }
    
    # Write report
    $reportFile = Join-Path $ReportDir "build-report.json"
    $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportFile -Encoding UTF8
    
    Write-Log "INFO" ""
    Write-Log "INFO" "======================================================"
    Write-Log "INFO" "BUILD SUMMARY"
    Write-Log "INFO" "======================================================"
    Write-Log "INFO" "Total:   $($report.summary.total)"
    Write-Log "INFO" "Success: $($report.summary.success)"
    Write-Log "INFO" "Failed:  $($report.summary.failed)"
    Write-Log "INFO" "Skipped: $($report.summary.skipped)"
    Write-Log "INFO" "Duration: $($report.duration)"
    Write-Log "INFO" "Report: $reportFile"
    Write-Log "INFO" "======================================================"
    
    if ($failedCount -gt 0) {
        Write-Log "ERROR" "BUILD COMPLETED WITH FAILURES"
        
        # List failed components
        Write-Log "ERROR" "Failed components:"
        $buildResults | Where-Object { $_.status -in @("FAILED", "ERROR") } | ForEach-Object {
            Write-Log "ERROR" "  - $($_.name): $($_.status) (exit: $($_.exitCode))"
        }
    }
    else {
        Write-Log "SUCCESS" "BUILD COMPLETED SUCCESSFULLY"
    }
}
catch {
    Write-Log "ERROR" "Orchestrator failed: $($_.Exception.Message)"
    $exitCode = 1
}

exit $exitCode
#endregion