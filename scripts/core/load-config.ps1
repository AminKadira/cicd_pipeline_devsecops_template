# scripts/core/load-config.ps1
# Version 2 - Support structure components avec scripts exploitation
# Exit codes: 0=OK, 1=Erreur, 2=Warning

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    [string]$GlobalConfigPath = "config/global.json",
    [string]$Workspace = $env:WORKSPACE
)

$ErrorActionPreference = "Stop"
$ScriptName = "load-config"

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    Write-Host "[$ScriptName][$Level] $Message" -ForegroundColor $(
        switch ($Level) { "ERROR" { "Red" } "WARNING" { "Yellow" } "SUCCESS" { "Green" } default { "White" } }
    )
}

function Write-EnvVar {
    param([string]$Key, [string]$Value)
    Write-Output "$Key=$Value"
}

function Get-ArrayAsString {
    param($Array, [string]$Separator = ";")
    if ($null -eq $Array -or $Array.Count -eq 0) { return "" }
    return ($Array | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) -join $Separator
}

function Resolve-Variable {
    param([string]$Template, [hashtable]$Vars)
    if ([string]::IsNullOrEmpty($Template)) { return $Template }
    $result = $Template
    foreach ($key in $Vars.Keys) {
        $result = $result -replace "\`$\{$key\}", $Vars[$key]
    }
    return $result
}

function Detect-ConfigVersion {
    param([object]$Config)
    if ($Config.components) { return "V2" }
    if ($Config.build.apis -is [array] -and $Config.build.apis[0] -is [string]) { return "V1" }
    return "V1"
}

# =============================================================================
# CHARGEMENT
# =============================================================================

Write-Log "INFO" "Loading configuration..."

if (-not (Test-Path $ConfigPath)) {
    Write-Log "ERROR" "Config not found: $ConfigPath"
    exit 1
}

if ([string]::IsNullOrEmpty($Workspace)) {
    $Workspace = (Get-Location).Path
}

# Normaliser environnement
$EnvLower = $Environment.ToLower()
$EnvDisplay = (Get-Culture).TextInfo.ToTitleCase($EnvLower)

try {
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Log "ERROR" "Failed to parse config: $($_.Exception.Message)"
    exit 1
}

# Charger global si existe
$global = $null
if (Test-Path $GlobalConfigPath) {
    try {
        $global = Get-Content -Path $GlobalConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Log "WARNING" "Failed to load global config"
    }
}

# Détecter version
$configVersion = Detect-ConfigVersion -Config $config
Write-Log "INFO" "Config version detected: $configVersion"

# Variables de substitution
$vars = @{
    'WORKSPACE' = $Workspace
    'environment' = $EnvDisplay
}

# =============================================================================
# EXTRACTION - PROJET
# =============================================================================

$projectName = $config.project.name -replace '\.git$', ''
$projectKey = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
$projectStack = if ($config.project.stack) { $config.project.stack } else { "dotnet" }
$projectVersion = if ($config.project.version) { $config.project.version } else { "1.0.0" }

Write-EnvVar "PROJECT_NAME" $projectName
Write-EnvVar "PROJECT_KEY" $projectKey
Write-EnvVar "PROJECT_STACK" $projectStack
Write-EnvVar "PROJECT_VERSION" $projectVersion
Write-EnvVar "CONFIG_VERSION" $configVersion

# =============================================================================
# EXTRACTION - REPOSITORY
# =============================================================================

Write-EnvVar "GIT_URL" $config.project.gitUrl
Write-EnvVar "GIT_BRANCH" $(if ($config.project.gitBranch) { $config.project.gitBranch } else { "main" })
Write-EnvVar "GIT_CREDENTIALS" $(if ($config.project.gitCredentials) { $config.project.gitCredentials } else { "git-ssh-key" })

# =============================================================================
# EXTRACTION - AGENT
# =============================================================================

# V2: section agent dédiée
if ($config.agent) {
    $agentOs = $config.agent.os
    $agentLabel = $config.agent.label
    $agentFallback = $config.agent.fallbackLabel
} else {
    # V1: dans project.jenkinsAgent
    $agentLabel = $config.project.jenkinsAgent
    $agentOs = if ($agentLabel -match "linux|lnx") { "linux" } else { "windows" }
    $agentFallback = ""
}

Write-EnvVar "AGENT_OS" $agentOs
Write-EnvVar "AGENT_LABEL" $agentLabel
Write-EnvVar "AGENT_FALLBACK" $agentFallback

# =============================================================================
# EXTRACTION - BUILD
# =============================================================================

# V2: section build.proxy
if ($config.build.proxy) {
    Write-EnvVar "PROXY_SERVER" $config.build.proxy.server
    Write-EnvVar "PROXY_PORT" $config.build.proxy.port
} else {
    # V1
    Write-EnvVar "PROXY_SERVER" $(if ($config.build.proxyServer) { $config.build.proxyServer } else { "" })
    Write-EnvVar "PROXY_PORT" $(if ($config.build.proxyPort) { $config.build.proxyPort } else { "" })
}

$baseFolder = Resolve-Variable -Template $config.build.defaultBaseFolder -Vars $vars
$publishFolder = Resolve-Variable -Template $config.build.publishFolder -Vars $vars
Write-EnvVar "BUILD_BASE_FOLDER" $baseFolder
Write-EnvVar "BUILD_PUBLISH_FOLDER" $publishFolder

# =============================================================================
# EXTRACTION - COMPONENTS (V2) ou APIS (V1)
# =============================================================================

if ($configVersion -eq "V2") {
    # Compter les composants par catégorie
    $categories = @('apis', 'webApps', 'consoleServices', 'batches', 'angular', 'dbScripts')
    $totalComponents = 0
    
    foreach ($cat in $categories) {
        $items = $config.components.$cat | Where-Object { $_.enabled -ne $false }
        $count = if ($items) { @($items).Count } else { 0 }
        $names = if ($items) { ($items | ForEach-Object { $_.name }) -join "," } else { "" }
        
        $catUpper = $cat.ToUpper()
        Write-EnvVar "COMPONENTS_${catUpper}_COUNT" $count
        Write-EnvVar "COMPONENTS_${catUpper}_LIST" $names
        $totalComponents += $count
    }
    
    Write-EnvVar "COMPONENTS_TOTAL" $totalComponents
    Write-EnvVar "HAS_COMPONENTS" $(if ($totalComponents -gt 0) { "true" } else { "false" })
    
} else {
    # V1: Structure plate
    $apis = if ($config.build.apis) { $config.build.apis } else { @() }
    Write-EnvVar "APIS_LIST" (Get-ArrayAsString $apis ",")
    Write-EnvVar "APIS_COUNT" $apis.Count
    Write-EnvVar "BUILD_SCRIPT_PATH" $config.build.scriptPath
    Write-EnvVar "COMPONENTS_TOTAL" $apis.Count
    Write-EnvVar "HAS_COMPONENTS" $(if ($apis.Count -gt 0) { "true" } else { "false" })
}

# =============================================================================
# EXTRACTION - SECURITY
# =============================================================================

# GitLeaks
$gitleaksEnabled = "false"
if ($config.security.gitleaks.enabled -eq $true -or $config.security.secretsScan.enabled -eq $true) {
    $gitleaksEnabled = "true"
}
Write-EnvVar "SECURITY_GITLEAKS_ENABLED" $gitleaksEnabled
Write-EnvVar "SECURITY_GITLEAKS_CONFIG" $(if ($config.security.gitleaks.configFile) { $config.security.gitleaks.configFile } else { "config/gitleaks.toml" })

# OWASP DC
$owaspEnabled = "false"
if ($config.security.owaspDC.enabled -eq $true -or $config.security.dependencyScan.enabled -eq $true) {
    $owaspEnabled = "true"
}
Write-EnvVar "SECURITY_OWASPDC_ENABLED" $owaspEnabled
Write-EnvVar "SECURITY_OWASPDC_FAILONCVSS" $(
    if ($config.security.owaspDC.failOnCVSS) { $config.security.owaspDC.failOnCVSS }
    elseif ($config.security.dependencyScan.failOnCVSS) { $config.security.dependencyScan.failOnCVSS }
    else { "7.0" }
)

# SonarQube
$sonarEnabled = "false"
if ($config.security.sonar.enabled -eq $true -or $config.security.codeAnalysis.enabled -eq $true) {
    $sonarEnabled = "true"
}
Write-EnvVar "SECURITY_SONAR_ENABLED" $sonarEnabled
Write-EnvVar "SECURITY_SONAR_PROJECTKEY" $(
    if ($config.security.sonar.projectKey) { $config.security.sonar.projectKey }
    else { "BRS.FR.$projectName" }
)

Write-EnvVar "SECURITY_FAIL_ON_CRITICAL" $(if ($config.security.dependencyScan.failOnCritical -eq $true) { "true" } else { "false" })
Write-EnvVar "SECURITY_FAIL_ON_HIGH" $(if ($config.security.dependencyScan.failOnHigh -eq $true) { "true" } else { "false" })

# =============================================================================
# EXTRACTION - ENVIRONMENT
# =============================================================================

$envConfig = $null

# Chercher dans environments (V2) ou project.environments (V1)
$envList = if ($config.environments) { $config.environments } else { $config.project.environments }
if ($envList) {
    $envConfig = $envList | Where-Object { $_.name -eq $EnvLower -or $_.name -eq $EnvDisplay } | Select-Object -First 1
}

if ($envConfig) {
    Write-EnvVar "ENV_NAME" $EnvLower
    Write-EnvVar "ENV_DISPLAY_NAME" $(if ($envConfig.displayName) { $envConfig.displayName } else { $EnvDisplay })
    
    $servers = if ($envConfig.targetServers) { $envConfig.targetServers } else { @() }
    Write-EnvVar "ENV_SERVERS" (Get-ArrayAsString $servers)
    Write-EnvVar "ENV_SERVERS_COUNT" $servers.Count
    Write-EnvVar "ENV_AUTO_DEPLOY" $(if ($envConfig.autoDeploy -eq $false) { "false" } else { "true" })
    Write-EnvVar "ENV_APPROVAL_REQUIRED" $(if ($envConfig.approvalRequired -eq $true) { "true" } else { "false" })
    Write-EnvVar "DEPLOY_ENABLED" $(if ($servers.Count -gt 0) { "true" } else { "false" })
    
    # Agent override par environnement
    if ($envConfig.jenkinsAgent) {
        Write-EnvVar "ENV_AGENT_OVERRIDE" $envConfig.jenkinsAgent
    }
} else {
    Write-Log "WARNING" "Environment '$Environment' not found, using defaults"
    Write-EnvVar "ENV_NAME" $EnvLower
    Write-EnvVar "ENV_DISPLAY_NAME" $EnvDisplay
    Write-EnvVar "ENV_SERVERS" ""
    Write-EnvVar "ENV_SERVERS_COUNT" "0"
    Write-EnvVar "DEPLOY_ENABLED" "false"
}

# =============================================================================
# EXTRACTION - DEPLOY
# =============================================================================

if ($config.deploy) {
    Write-EnvVar "DEPLOY_SCRIPT_PATH" $(Resolve-Variable -Template $config.deploy.scriptPath -Vars $vars)
    Write-EnvVar "DEPLOY_STRATEGY" $(if ($config.deploy.strategy) { $config.deploy.strategy } else { "all-at-once" })
    Write-EnvVar "DEPLOY_HEALTH_CHECK" $(if ($config.deploy.healthCheck.enabled -eq $true) { "true" } else { "false" })
    Write-EnvVar "DEPLOY_HEALTH_ENDPOINT" $(if ($config.deploy.healthCheck.endpoint) { $config.deploy.healthCheck.endpoint } else { "/health" })
}

# =============================================================================
# EXTRACTION - NOTIFICATIONS
# =============================================================================

Write-EnvVar "NOTIFY_DEVTEAM" (Get-ArrayAsString $config.notifications.devteam)
Write-EnvVar "NOTIFY_QATEAM" (Get-ArrayAsString $config.notifications.qateam)
Write-EnvVar "NOTIFY_SECURITY" (Get-ArrayAsString $config.notifications.securityTeam)

# =============================================================================
# DONE
# =============================================================================

Write-Log "SUCCESS" "Configuration loaded: $projectName ($configVersion)"
exit 0