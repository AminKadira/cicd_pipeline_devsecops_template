param(
    [string]$projectKey
)

#region Validation & Error Handling
if (-not $projectKey) {
    throw "ProjectKey parameter is required"
}

$projectConfigPath = "config/projects/$projectKey.json"
if (-not (Test-Path $projectConfigPath)) {
    throw "Project configuration file not found: $projectConfigPath"
}

$environment = $env:ENVIRONMENT
if (-not $environment) {
    throw "ENVIRONMENT variable not set. Ensure it's defined in Jenkins pipeline parameters."
}
#endregion 

#region Load Configuration
try {
    $projectConfig = Get-Content $projectConfigPath | ConvertFrom-Json
} catch {
    throw "Failed to parse JSON configuration: $_"
}
#endregion

#region Project & Build Information
Write-Output "PROJECT_KEY=$projectKey"
Write-Output "ENVIRONMENT_NAME=$environment"
Write-Output "PROJECT_NAME=$($projectConfig.project.name)"
Write-Output "PROJECT_GIT_URL=$($projectConfig.project.gitUrl)"
Write-Output "PROJECT_GIT_BRANCH=$($projectConfig.project.gitBranch)"
Write-Output "PROJECT_GIT_CREDENTIALS=$($projectConfig.project.gitCredentials)"
Write-Output "BUILD_SCRIPT_PATH=$($projectConfig.build.scriptPath)"
Write-Output "PROXY_SERVER=$($projectConfig.build.proxyServer)"
Write-Output "PROXY_PORT=$($projectConfig.build.proxyPort)"
Write-Output "APIS_LIST=$($projectConfig.build.apis -join ',')"
Write-Output "APIS_COUNT=$($projectConfig.build.apis.Count)"
#endregion

#region Security Configuration
Write-Output "SECURITY_SCAN_ENABLED=$($projectConfig.security.dependencyScan.enabled)"
Write-Output "FAIL_ON_CRITICAL=$($projectConfig.security.dependencyScan.failOnCritical)"
Write-Output "FAIL_ON_HIGH=$($projectConfig.security.dependencyScan.failOnHigh)"
#endregion

#region Environment & Deployment Resolution
$envNameLower = $environment.ToLower()
$projectEnv = $projectConfig.project.environments |
    Where-Object { $_.name.ToLower() -eq $envNameLower } |
    Select-Object -First 1

$jenkinsAgent = ""
if ($projectConfig.project.jenkinsAgent) {
    $jenkinsAgent = $projectConfig.project.jenkinsAgent
}
if ($projectEnv -and $projectEnv.jenkinsAgent) {
    # l'agent défini au niveau environnement écrase la valeur projet
    $jenkinsAgent = $projectEnv.jenkinsAgent
}

if ($projectEnv -and $projectEnv.targetServers -and $projectEnv.targetServers.Count -gt 0) {
    $servers = $projectEnv.targetServers
    $deployEnabled = $true
} else {
    $servers = @()
    $deployEnabled = $false
}

# Environment list
$envNames = @()
if ($projectConfig.project.environments) {
    $envNames = $projectConfig.project.environments | 
        ForEach-Object { $_.name } |
        Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 }
}

Write-Output "ENVIRONMENTS_LIST=$($envNames -join ',')"
Write-Output "ENVIRONMENTS_COUNT=$($envNames.Count)"
#endregion

#region Notification Emails
function Get-NotificationEmails {
    param(
        [object]$notificationConfig,
        [string]$teamKey
    )
    
    if (-not $notificationConfig.$teamKey) {
        return @()
    }
    
    $emails = $notificationConfig.$teamKey
    if ($emails -is [System.Array]) {
        return $emails
    } else {
        return @($emails)
    }
}

$devEmails      = Get-NotificationEmails -notificationConfig $projectConfig.notifications -teamKey "devteam"
$qaEmails       = Get-NotificationEmails -notificationConfig $projectConfig.notifications -teamKey "qateam"
$securityEmails = Get-NotificationEmails -notificationConfig $projectConfig.notifications -teamKey "securityTeam"

# Combine and deduplicate
$allNotificationEmails = @($devEmails + $qaEmails) | 
    Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 } | 
    Select-Object -Unique

$allSecurityEmails = $securityEmails | 
    Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 } | 
    Select-Object -Unique

Write-Output "DEPLOY_ENABLED=$deployEnabled"
Write-Output "JENKINS_AGENT_LABEL=$jenkinsAgent"
Write-Output "NOTIFICATION_EMAIL=$($allNotificationEmails -join ';')"
Write-Output "SECURITY_EMAIL=$($allSecurityEmails -join ';')"

# Individual team emails
Write-Output "DEVTEAM_EMAILS=$($devEmails -join ';')"
Write-Output "QATEAM_EMAILS=$($qaEmails -join ';')"
Write-Output "SECURITYTEAM_EMAILS=$($securityEmails -join ';')"
#endregion

#region Deployment Servers
Write-Output "DEPLOY_SERVERS=$($servers -join ';')"
Write-Output "DEPLOY_VMS_COUNT=$($servers.Count)"
#endregion