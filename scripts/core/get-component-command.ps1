# scripts/core/get-component-command.ps1
# Génère la commande de build ou deploy pour un composant spécifique
# Exit codes: 0=OK, 1=Erreur

param(
    [Parameter(Mandatory=$true)]
    [string]$ComponentsFile,
    
    [Parameter(Mandatory=$true)]
    [string]$ComponentName,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("build", "deploy")]
    [string]$Action,
    
    [string]$TargetServer = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptName = "get-component-command"

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    Write-Host "[$ScriptName][$Level] $Message" -ForegroundColor $(
        switch ($Level) { "ERROR" { "Red" } "WARNING" { "Yellow" } default { "White" } }
    )
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
    exit 1
}

try {
    $data = Get-Content -Path $ComponentsFile -Raw | ConvertFrom-Json
} catch {
    Write-Log "ERROR" "Failed to parse components file: $($_.Exception.Message)"
    exit 1
}

# Trouver le composant
$component = $data.components | Where-Object { $_.name -eq $ComponentName } | Select-Object -First 1

if (-not $component) {
    Write-Log "ERROR" "Component not found: $ComponentName"
    Write-Log "ERROR" "Available components: $(($data.components | ForEach-Object { $_.name }) -join ', ')"
    exit 1
}

# =============================================================================
# GÉNÉRATION COMMANDE
# =============================================================================

$actionConfig = $component.$Action

if (-not $actionConfig -or -not $actionConfig.script) {
    Write-Log "ERROR" "No $Action configuration for component: $ComponentName"
    exit 1
}

$script = $actionConfig.script
$params = $actionConfig.params

# Substituer ${server} si présent dans les params de deploy
if ($Action -eq "deploy" -and $TargetServer) {
    $params = $params | ConvertTo-Json | ForEach-Object { $_ -replace '\$\{server\}', $TargetServer } | ConvertFrom-Json
}

# Construire les arguments
$arguments = @()
foreach ($prop in $params.PSObject.Properties) {
    $value = $prop.Value
    # Échapper les espaces
    if ($value -match '\s') {
        $value = "`"$value`""
    }
    $arguments += "-$($prop.Name) $value"
}

# Ajouter paramètres communs selon le type
if ($component.category -eq 'apis' -or $component.category -eq 'webApps' -or $component.category -eq 'consoleServices') {
    $arguments += "-assemblyName `"$ComponentName`""
}

if ($Action -eq "deploy" -and $TargetServer) {
    $arguments += "-server `"$TargetServer`""
}

$argumentString = $arguments -join " "
$fullCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$script`" $argumentString"

Write-Log "INFO" "Component: $ComponentName ($($component.category))"
Write-Log "INFO" "Action: $Action"
Write-Log "INFO" "Script: $script"

if ($DryRun) {
    Write-Log "INFO" "DRY RUN - Command would be:"
    Write-Host $fullCommand
} else {
    Write-EnvVar "COMPONENT_NAME" $ComponentName
    Write-EnvVar "COMPONENT_CATEGORY" $component.category
    Write-EnvVar "COMPONENT_SCRIPT" $script
    Write-EnvVar "COMPONENT_ARGS" $argumentString
    Write-EnvVar "COMPONENT_COMMAND" $fullCommand
}

exit 0