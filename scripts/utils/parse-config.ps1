# scripts/utils/parse-config.ps1
# =============================================================================
# Pipeline Configuration Parser v2.0
# Compatible avec template v2.0.0
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$projectKey,
    
    [Parameter(Mandatory = $false)]
    [string]$environment = $env:ENVIRONMENT
)

$ErrorActionPreference = "Stop"
$APIS = "apis"
$LISTENERS = "listeners"
$CONSOLE = "console"
$JOB = "job"
$BATCHS = "batchs"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Get-SafeValue {
    param($value, $default = "")
    if ($null -eq $value -or $value -eq "") { return $default }
    return $value
}

function Write-ConfigOutput {
    param([string]$key, $value)
    if ($null -ne $value) {
        Write-Output "${key}=${value}"
    }
}

function Find-ProjectConfig {
    param([string]$projectKey)
    
    $searchPaths = @(
        "config/projects/$projectKey.json",
        "config/projects/*/$projectKey.json",
        "config/projects/*/*/$projectKey.json"
    )
    
    foreach ($pattern in $searchPaths) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-EnabledComponents {
    param([object]$components)
    
    $result = @()
    $componentTypes = @($APIS, $LISTENERS, $CONSOLE, $JOB, $BATCHS)
    
    foreach ($type in $componentTypes) {
        $section = $components.$type
        
        Write-Host "DEBUG: [$type] section exists: $($null -ne $section)"
        if ($section) {
            Write-Host "DEBUG: [$type] enabled: $($section.enabled)"
            Write-Host "DEBUG: [$type] items count: $($section.items.Count)"
        }

        if ($section -and $section.enabled -and $section.items) {
            $items = @($section.items)
            foreach ($item in $items) {
                $result += [PSCustomObject]@{
                    Name         = $item.name
                    Type         = $item.type
                    Category     = $type
                    BuildScript  = Get-SafeValue $item.scriptPath_build
                    DeployScript = Get-SafeValue $item.scriptPath_deploy
                    DestPath     = Get-SafeValue $item.destPath

                }
                Write-Host "DEBUG: [$type] Added component: $($item.name)"

            }
        }
    }
    Write-Host "DEBUG: Total components found: $($result.Count)"
    return @($result)
}

function Get-EmailList {
    param([object]$config, [string]$key)
    
    if (-not $config -or -not $config.$key) { return @() }
    $emails = $config.$key
    if ($emails -is [System.Array]) { return $emails }
    return @($emails)
}

# =============================================================================
# VALIDATION
# =============================================================================

if (-not $projectKey) {
    throw "ERROR: projectKey parameter is required"
}

$projectConfigPath = Find-ProjectConfig -projectKey $projectKey
if (-not $projectConfigPath) {
    throw "ERROR: Project configuration not found for key: $projectKey"
}

$globalConfigPath = "config/global.json"
$globalConfig = $null
if (Test-Path $globalConfigPath) {
    try {
        $globalConfig = Get-Content $globalConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Failed to parse global.json: $_"
    }
}

if (-not $environment) {
    $environment = "tst"
}

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

try {
    $config = Get-Content $projectConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "ERROR: Failed to parse project configuration: $_"
}

# =============================================================================
# OUTPUT: METADATA
# =============================================================================

Write-ConfigOutput "CONFIG_VERSION" "2.0.0"
Write-ConfigOutput "CONFIG_PATH" $projectConfigPath
Write-ConfigOutput "PROJECT_KEY" $projectKey
Write-ConfigOutput "ENVIRONMENT_NAME" $environment

# =============================================================================
# OUTPUT: PROJECT
# =============================================================================

Write-ConfigOutput "PROJECT_NAME" (Get-SafeValue $config.project.name)
Write-ConfigOutput "PROJECT_DESCRIPTION" (Get-SafeValue $config.project.description)
Write-ConfigOutput "PROJECT_TEAM" (Get-SafeValue $config.project.team)
Write-ConfigOutput "PROJECT_GIT_URL" (Get-SafeValue $config.project.gitUrl)
Write-ConfigOutput "PROJECT_GIT_BRANCH" (Get-SafeValue $config.project.gitBranch "main")
Write-ConfigOutput "PROJECT_GIT_CREDENTIALS" (Get-SafeValue $config.project.gitCredentials "git-ssh-key")
Write-ConfigOutput "TRIGGER_REPO_PATTERN" (Get-SafeValue $config.project.triggerRepoPattern)

# =============================================================================
# OUTPUT: BUILD
# =============================================================================

Write-ConfigOutput "BUILD_FRAMEWORK" (Get-SafeValue $config.build.framework ".NET Core 3.1")
Write-ConfigOutput "BUILD_CONFIGURATION" (Get-SafeValue $config.build.configuration "Release")
Write-ConfigOutput "BUILD_VERBOSITY" (Get-SafeValue $config.build.verbosity "normal")
Write-ConfigOutput "BUILD_RESTORE_PACKAGES" (Get-SafeValue $config.build.restorePackages $true)
Write-ConfigOutput "BUILD_RUN_TESTS" (Get-SafeValue $config.build.runTests $false)

# Proxy (global > project fallback)
$proxyServer = if ($globalConfig) { $globalConfig.services.proxy.server } else { $config.build.proxyServer }
$proxyPort = if ($globalConfig) { $globalConfig.services.proxy.port } else { $config.build.proxyPort }
Write-ConfigOutput "PROXY_SERVER" (Get-SafeValue $proxyServer "proxy.fr.laridak.tools")
Write-ConfigOutput "PROXY_PORT" (Get-SafeValue $proxyPort "3128")

# =============================================================================
# OUTPUT: COMPONENTS
# =============================================================================

$components = @(Get-EnabledComponents -components $config.components)
Write-ConfigOutput "COMPONENTS_COUNT" $components.Count

# Export par index (pour Jenkins)
for ($i = 0; $i -lt $components.Count; $i++) {
 $comp = $components[$i]
    Write-ConfigOutput "COMPONENT_${i}_NAME" $comp.Name
    Write-ConfigOutput "COMPONENT_${i}_TYPE" $comp.Type
    Write-ConfigOutput "COMPONENT_${i}_CATEGORY" $comp.Category
    Write-ConfigOutput "COMPONENT_${i}_BUILD_SCRIPT" $comp.BuildScript
    Write-ConfigOutput "COMPONENT_${i}_BUILD_SCRIPT_NAME" ([System.IO.Path]::GetFileNameWithoutExtension($comp.BuildScript))
    Write-ConfigOutput "COMPONENT_${i}_DEPLOY_SCRIPT" $comp.DeployScript
    Write-ConfigOutput "COMPONENT_${i}_DEPLOY_SCRIPT_NAME" ([System.IO.Path]::GetFileNameWithoutExtension($comp.DeployScript))
    Write-ConfigOutput "COMPONENT_${i}_BASE_FOLDER" $comp.BaseFolder
    Write-ConfigOutput "COMPONENT_${i}_PUBLISH_FOLDER" $comp.PublishFolder
    Write-ConfigOutput "COMPONENT_${i}_DEST_PATH" $comp.DestPath
}

# Export listes par catégorie
$categories = @($APIS, $LISTENERS, $CONSOLE, $JOB, $BATCHS)
foreach ($cat in $categories) {
    $items = $components | Where-Object { $_.Category -eq $cat }
    $names = ($items | ForEach-Object { $_.Name }) -join ','
    $count = $items.Count
    Write-ConfigOutput "$($cat.ToUpper())_LIST" $names
    Write-ConfigOutput "$($cat.ToUpper())_COUNT" $count
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Get-SafeValue {
    param($value, $default = "")
    if ($null -eq $value) { return $default }
    return $value
}

function Get-BoolValue {
    param($value, [bool]$default = $true)
    if ($null -eq $value) { return $default }
    if ($value -is [bool]) { return $value }
    if ($value -is [string]) {
        return $value.ToLower() -in @('true', '1', 'yes', 'on')
    }
    return [bool]$value
}

# =============================================================================
# OUTPUT: SECURITY
# =============================================================================

# GitLeaks
Write-ConfigOutput "GITLEAKS_ENABLED" (Get-BoolValue $config.security.gitleaks.enabled $false)
Write-ConfigOutput "GITLEAKS_CONFIG" (Get-SafeValue $config.security.gitleaks.configFile "config/gitleaks.toml")
Write-ConfigOutput "GITLEAKS_SCAN_HISTORY" (Get-BoolValue $config.security.gitleaks.scanHistory $false)
Write-ConfigOutput "GITLEAKS_BASELINE" (Get-SafeValue $config.security.gitleaks.baselineFile)

# Dependency Scan
Write-ConfigOutput "DEPENDENCY_SCAN_ENABLED" (Get-BoolValue $config.security.dependencyScan.enabled $false)
Write-ConfigOutput "DEPENDENCY_SCAN_TOOL" (Get-SafeValue $config.security.dependencyScan.tool "dotnet-native")
Write-ConfigOutput "FAIL_ON_CRITICAL" (Get-BoolValue $config.security.dependencyScan.failOnCritical $true)
Write-ConfigOutput "FAIL_ON_HIGH" (Get-BoolValue $config.security.dependencyScan.failOnHigh $true)
Write-ConfigOutput "FAIL_ON_MEDIUM" (Get-BoolValue $config.security.dependencyScan.failOnMedium $false)

# OWASP DC
Write-ConfigOutput "OWASP_DC_ENABLED" (Get-BoolValue $config.security.owaspDependencyCheck.enabled $false)
Write-ConfigOutput "OWASP_DC_FAIL_CVSS" (Get-SafeValue $config.security.owaspDependencyCheck.failOnCVSS 7.0)
Write-ConfigOutput "OWASP_DC_SUPPRESSION" (Get-SafeValue $config.security.owaspDependencyCheck.suppressionFile)
Write-ConfigOutput "OWASP_DC_OFFLINE" (Get-BoolValue $config.security.owaspDependencyCheck.offlineMode $true)
Write-ConfigOutput "OWASP_DC_NVD_FEEDS" (Get-SafeValue $config.security.owaspDependencyCheck.nvdFeedsDir)

# SonarQube
Write-ConfigOutput "SONAR_ENABLED" (Get-BoolValue $config.security.codeAnalysis.enabled $false)
Write-ConfigOutput "SONAR_PROJECT_PREFIX" (Get-SafeValue $config.security.codeAnalysis.projectKeyPrefix "BRS.FR.")

# DAST
Write-ConfigOutput "DAST_ENABLED" (Get-BoolValue $config.security.dast.enabled $false)
Write-ConfigOutput "DAST_TOOL" (Get-SafeValue $config.security.dast.tool "OWASP ZAP")

# =============================================================================
# OUTPUT: TESTING
# =============================================================================

Write-ConfigOutput "UNIT_TESTS_ENABLED" (Get-SafeValue $config.testing.unit.enabled $false)
Write-ConfigOutput "INTEGRATION_TESTS_ENABLED" (Get-SafeValue $config.testing.integration.enabled $false)
Write-ConfigOutput "HEALTH_CHECK_ENABLED" (Get-SafeValue $config.testing.healthCheck.enabled $true)
Write-ConfigOutput "HEALTH_CHECK_ENDPOINT" (Get-SafeValue $config.testing.healthCheck.endpoint "/health")
Write-ConfigOutput "HEALTH_CHECK_TIMEOUT" (Get-SafeValue $config.testing.healthCheck.timeout 120)
Write-ConfigOutput "HEALTH_CHECK_RETRIES" (Get-SafeValue $config.testing.healthCheck.retries 5)

# =============================================================================
# OUTPUT: ENVIRONMENT & DEPLOYMENT
# =============================================================================

$envLower = $environment.ToLower()
$envConfig = $config.project.environments | Where-Object { $_.name.ToLower() -eq $envLower } | Select-Object -First 1

# Jenkins Agent
$jenkinsAgent = Get-SafeValue $config.project.jenkinsAgent "larivm-l1pi027"
if ($envConfig -and $envConfig.jenkinsAgent) {
    $jenkinsAgent = $envConfig.jenkinsAgent
}
Write-ConfigOutput "JENKINS_AGENT_LABEL" $jenkinsAgent

# Environments list
$envNames = ($config.project.environments | ForEach-Object { $_.name }) -join ','
Write-ConfigOutput "ENVIRONMENTS_LIST" $envNames
Write-ConfigOutput "ENVIRONMENTS_COUNT" $config.project.environments.Count

# Deployment
$deployEnabled = $false
$servers = @()
$requiresApproval = $false
$approvers = @()

if ($envConfig) {
    $deployEnabled = Get-SafeValue $envConfig.deployEnabled $false
    if ($envConfig.targetServers) { $servers = $envConfig.targetServers }
    $requiresApproval = Get-SafeValue $envConfig.requiresApproval $false
    if ($envConfig.approvers) { $approvers = $envConfig.approvers }
}

Write-ConfigOutput "DEPLOY_ENABLED" $deployEnabled
Write-ConfigOutput "DEPLOY_SERVERS" ($servers -join ';')
Write-ConfigOutput "DEPLOY_VMS_COUNT" $servers.Count
Write-ConfigOutput "DEPLOY_REQUIRES_APPROVAL" $requiresApproval
Write-ConfigOutput "DEPLOY_APPROVERS" ($approvers -join ',')
Write-ConfigOutput "DEPLOY_SCRIPT" (Get-SafeValue $config.deploy.scriptPath)
Write-ConfigOutput "DEPLOY_STRATEGY" (Get-SafeValue $config.deploy.strategy.$envLower "all-at-once")
Write-ConfigOutput "DEPLOY_HEALTH_CHECK" (Get-SafeValue $config.deploy.healthCheckAfterDeploy $true)
Write-ConfigOutput "ROLLBACK_ENABLED" (Get-SafeValue $config.deploy.rollback.enabled $true)
Write-ConfigOutput "ROLLBACK_KEEP_VERSIONS" (Get-SafeValue $config.deploy.rollback.keepVersions 3)

# =============================================================================
# OUTPUT: NOTIFICATIONS
# =============================================================================

$devEmails = Get-EmailList -config $config.notifications -key "devteam"
$qaEmails = Get-EmailList -config $config.notifications -key "qateam"
$secEmails = Get-EmailList -config $config.notifications -key "securityTeam"
$allEmails = @($devEmails + $qaEmails) | Where-Object { $_ } | Select-Object -Unique

Write-ConfigOutput "NOTIFICATION_EMAILS" ($allEmails -join ';')
Write-ConfigOutput "DEVTEAM_EMAILS" ($devEmails -join ';')
Write-ConfigOutput "QATEAM_EMAILS" ($qaEmails -join ';')
Write-ConfigOutput "SECURITY_EMAILS" ($secEmails -join ';')
Write-ConfigOutput "NOTIFY_ON_SUCCESS" (Get-SafeValue $config.notifications.onSuccess $false)
Write-ConfigOutput "NOTIFY_ON_FAILURE" (Get-SafeValue $config.notifications.onFailure $true)
Write-ConfigOutput "NOTIFY_ON_UNSTABLE" (Get-SafeValue $config.notifications.onUnstable $true)

# =============================================================================
# OUTPUT: QUALITY GATES
# =============================================================================

Write-ConfigOutput "FAIL_ON_SECURITY_ISSUES" (Get-SafeValue $config.quality.failBuild.onSecurityIssues $true)
Write-ConfigOutput "FAIL_ON_TEST_FAILURE" (Get-SafeValue $config.quality.failBuild.onTestFailure $true)
Write-ConfigOutput "FAIL_ON_BUILD_FAILURE" (Get-SafeValue $config.quality.failBuild.onBuildFailure $true)
Write-ConfigOutput "FAIL_ON_DEPLOY_FAILURE" (Get-SafeValue $config.quality.failBuild.onDeploymentFailure $true)
Write-ConfigOutput "FAIL_ON_QUALITY_GATE" (Get-SafeValue $config.quality.failBuild.onQualityGateFail $false)

# =============================================================================
# OUTPUT: LOGGING
# =============================================================================

Write-ConfigOutput "LOG_LEVEL" (Get-SafeValue $config.logging.level "INFO")
Write-ConfigOutput "LOG_RETENTION_BUILDS" (Get-SafeValue $config.logging.retention.builds 30)
Write-ConfigOutput "LOG_RETENTION_DAYS" (Get-SafeValue $config.logging.retention.daysToKeep 90)
Write-ConfigOutput "ARCHIVE_ARTIFACTS" (Get-SafeValue $config.logging.archiveArtifacts $true)