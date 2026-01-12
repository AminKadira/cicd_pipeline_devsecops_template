# scripts/core/execute-components.ps1
# Exécute le build ou deploy de tous les composants d'une catégorie
# Exit codes: 0=OK, 1=Erreur partielle, 2=Erreur totale

param(
    [Parameter(Mandatory=$true)]
    [string]$ComponentsFile,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("build", "deploy")]
    [string]$Action,
    
    [string]$Category = "",
    [string]$TargetServer = "",
    [switch]$StopOnError,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptName = "execute-components"

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$ScriptName][$Level] $Message" -ForegroundColor $color
}

function Write-EnvVar {
    param([string]$Key, [string]$Value)
    Write-Output "$Key=$Value"
}

# =============================================================================
# CHARGEMENT
# =============================================================================

if (-not (Test-Path $ComponentsFile)) {
    Write-Log "ERROR" "Components file not found: $ComponentsFile"
    exit 2
}

try {
    $data = Get-Content -Path $ComponentsFile -Raw | ConvertFrom-Json
} catch {
    Write-Log "ERROR" "Failed to parse: $($_.Exception.Message)"
    exit 2
}

# Filtrer par catégorie si spécifiée
$components = $data.components
if ($Category) {
    $components = $components | Where-Object { $_.category -eq $Category }
}

if ($components.Count -eq 0) {
    Write-Log "WARNING" "No components to process"
    exit 0
}

Write-Log "INFO" "======================================================="
Write-Log "INFO" "EXECUTING $($Action.ToUpper()) FOR $($components.Count) COMPONENT(S)"
Write-Log "INFO" "======================================================="
Write-Log "INFO" "Project: $($data.project)"
Write-Log "INFO" "Environment: $($data.environment)"
if ($Category) { Write-Log "INFO" "Category filter: $Category" }
if ($TargetServer) { Write-Log "INFO" "Target server: $TargetServer" }
Write-Log "INFO" ""

# =============================================================================
# EXÉCUTION
# =============================================================================

$results = @()
$successCount = 0
$failCount = 0
$index = 1

foreach ($component in $components) {
    Write-Log "INFO" "-------------------------------------------------------"
    Write-Log "INFO" "[$index/$($components.Count)] $($component.name) ($($component.category))"
    Write-Log "INFO" "-------------------------------------------------------"
    
    $actionConfig = $component.$Action
    
    if (-not $actionConfig -or -not $actionConfig.script) {
        Write-Log "WARNING" "No $Action config for: $($component.name)"
        $results += [PSCustomObject]@{
            name = $component.name
            category = $component.category
            status = "SKIPPED"
            reason = "No $Action configuration"
            duration = 0
        }
        $index++
        continue
    }
    
    $script = $actionConfig.script
    $params = $actionConfig.params
    
    # Vérifier que le script existe
    if (-not (Test-Path $script)) {
        Write-Log "ERROR" "Script not found: $script"
        $results += [PSCustomObject]@{
            name = $component.name
            category = $component.category
            status = "FAILED"
            reason = "Script not found: $script"
            duration = 0
        }
        $failCount++
        if ($StopOnError) {
            Write-Log "ERROR" "StopOnError enabled - aborting"
            break
        }
        $index++
        continue
    }
    
    # Construire les arguments
    $arguments = @{}
    foreach ($prop in $params.PSObject.Properties) {
        $value = $prop.Value
        # Substituer ${server} pour deploy
        if ($Action -eq "deploy" -and $TargetServer) {
            $value = $value -replace '\$\{server\}', $TargetServer
        }
        $arguments[$prop.Name] = $value
    }
    
    # Ajouter assemblyName pour les composants .NET
    if ($component.category -in @('apis', 'webApps', 'consoleServices')) {
        $arguments['assemblyName'] = $component.name
    }
    
    # Ajouter server pour deploy
    if ($Action -eq "deploy" -and $TargetServer) {
        $arguments['server'] = $TargetServer
    }
    
    # Ajouter environment
    $arguments['environment'] = $data.environment
    
    Write-Log "INFO" "Script: $script"
    Write-Log "INFO" "Parameters:"
    foreach ($key in $arguments.Keys) {
        $displayValue = $arguments[$key]
        if ($displayValue.Length -gt 60) {
            $displayValue = $displayValue.Substring(0, 57) + "..."
        }
        Write-Log "INFO" "  -$key = $displayValue"
    }
    
    if ($DryRun) {
        Write-Log "INFO" "DRY RUN - Skipping execution"
        $results += [PSCustomObject]@{
            name = $component.name
            category = $component.category
            status = "DRY_RUN"
            reason = ""
            duration = 0
        }
        $successCount++
    } else {
        $startTime = Get-Date
        
        try {
            # Exécuter le script
            $scriptResult = & $script @arguments
            $exitCode = $LASTEXITCODE
            
            $duration = ((Get-Date) - $startTime).TotalSeconds
            
            if ($exitCode -eq 0) {
                Write-Log "SUCCESS" "$($component.name) completed in $([math]::Round($duration, 1))s"
                $results += [PSCustomObject]@{
                    name = $component.name
                    category = $component.category
                    status = "SUCCESS"
                    reason = ""
                    duration = $duration
                }
                $successCount++
            } else {
                Write-Log "ERROR" "$($component.name) failed with exit code: $exitCode"
                $results += [PSCustomObject]@{
                    name = $component.name
                    category = $component.category
                    status = "FAILED"
                    reason = "Exit code: $exitCode"
                    duration = $duration
                }
                $failCount++
                
                if ($StopOnError) {
                    Write-Log "ERROR" "StopOnError enabled - aborting"
                    break
                }
            }
        } catch {
            $duration = ((Get-Date) - $startTime).TotalSeconds
            Write-Log "ERROR" "Exception: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                name = $component.name
                category = $component.category
                status = "FAILED"
                reason = $_.Exception.Message
                duration = $duration
            }
            $failCount++
            
            if ($StopOnError) {
                Write-Log "ERROR" "StopOnError enabled - aborting"
                break
            }
        }
    }
    
    $index++
}

# =============================================================================
# SUMMARY
# =============================================================================

Write-Log "INFO" ""
Write-Log "INFO" "======================================================="
Write-Log "INFO" "EXECUTION SUMMARY"
Write-Log "INFO" "======================================================="
Write-Log "INFO" "Total: $($results.Count)"
Write-Log "INFO" "Success: $successCount"
Write-Log "INFO" "Failed: $failCount"
Write-Log "INFO" "Skipped: $($results | Where-Object { $_.status -eq 'SKIPPED' }).Count"
Write-Log "INFO" ""

# Détail des résultats
foreach ($result in $results) {
    $statusIcon = switch ($result.status) {
        "SUCCESS" { "✓" }
        "FAILED" { "✗" }
        "SKIPPED" { "○" }
        "DRY_RUN" { "◌" }
        default { "?" }
    }
    $msg = "$statusIcon $($result.name) - $($result.status)"
    if ($result.reason) { $msg += " ($($result.reason))" }
    if ($result.duration -gt 0) { $msg += " [$([math]::Round($result.duration, 1))s]" }
    
    $color = switch ($result.status) {
        "SUCCESS" { "Green" }
        "FAILED" { "Red" }
        "SKIPPED" { "Yellow" }
        default { "White" }
    }
    Write-Host "  $msg" -ForegroundColor $color
}

Write-Log "INFO" "======================================================="

# Export results
Write-EnvVar "EXEC_TOTAL" $results.Count
Write-EnvVar "EXEC_SUCCESS" $successCount
Write-EnvVar "EXEC_FAILED" $failCount
Write-EnvVar "EXEC_SKIPPED" ($results | Where-Object { $_.status -eq 'SKIPPED' }).Count

# Exit code
if ($failCount -eq $results.Count) {
    exit 2  # Tout a échoué
} elseif ($failCount -gt 0) {
    exit 1  # Échec partiel
} else {
    exit 0  # Tout OK
}