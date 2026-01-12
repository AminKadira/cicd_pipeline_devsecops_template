# scripts/build/resolve-build-config.ps1
# Resolves and validates build configuration for a component

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$true)]
    [string]$ComponentName,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    [string]$GlobalConfigPath = "config/global.json"
)

$ErrorActionPreference = "Stop"
$ScriptName = "RESOLVE-BUILD-CONFIG"

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    Write-Output "[$ScriptName][$Level] $Message"
}

try {
    # Load configs
    $projectConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $globalConfig = if (Test-Path $GlobalConfigPath) {
        Get-Content $GlobalConfigPath -Raw | ConvertFrom-Json
    } else { $null }
    
    # Find component
    $component = $null
    $componentType = $null
    
    foreach ($type in @("apis", "webApps", "consoleServices", "batches", "workers")) {
        $found = $projectConfig.build.$type | Where-Object { $_.name -eq $ComponentName }
        if ($found) {
            $component = $found
            $componentType = $type
            break
        }
    }
    
    if (-not $component) {
        throw "Component not found: $ComponentName"
    }
    
    # Build variable context
    $variables = @{
        "WORKSPACE"      = $env:WORKSPACE ?? $PWD.Path
        "environment"    = $Environment
        "component.name" = $component.name
    }
    
    # Resolve script path
    $scriptPath = $component.script
    foreach ($key in $variables.Keys) {
        $scriptPath = $scriptPath -replace "\`$\{$key\}", $variables[$key]
    }
    
    # Build resolved params
    $resolvedParams = @{}
    
    if ($component.params) {
        $component.params.PSObject.Properties | ForEach-Object {
            $value = $_.Value
            foreach ($key in $variables.Keys) {
                $value = $value -replace "\`$\{$key\}", $variables[$key]
            }
            $resolvedParams[$_.Name] = $value
        }
    }
    
    # Add proxy if not present
    if ($globalConfig.proxy -and -not $resolvedParams.ContainsKey("proxyServer")) {
        $resolvedParams["proxyServer"] = $globalConfig.proxy.server
        $resolvedParams["proxyPort"] = $globalConfig.proxy.port
    }
    
    # Add environment if not present
    if (-not $resolvedParams.ContainsKey("environment")) {
        $resolvedParams["environment"] = $Environment
    }
    
    # Output resolved configuration
    $resolved = @{
        componentName = $component.name
        componentType = $componentType
        scriptPath    = $scriptPath
        params        = $resolvedParams
        enabled       = if ($component.PSObject.Properties["enabled"]) { $component.enabled } else { $true }
    }
    
    $resolved | ConvertTo-Json -Depth 5
    
} catch {
    Write-Log "ERROR" $_.Exception.Message
    exit 1
}