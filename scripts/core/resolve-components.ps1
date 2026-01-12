# scripts/core/resolve-components.ps1
# Extrait et prépare les composants depuis la config V2
# Génère un fichier JSON avec tous les composants résolus et variables substituées
# Exit codes: 0=OK, 1=Erreur

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("tst", "sta", "prd", "dev", "uat", "Tst", "Sta", "Prd")]
    [string]$Environment,
    
    [string]$Workspace = $env:WORKSPACE,
    [string]$OutputFile = "",
    [switch]$BuildOnly,
    [switch]$DeployOnly,
    [string]$TargetServer = ""
)

$ErrorActionPreference = "Stop"
$ScriptName = "resolve-components"

function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    Write-Host "[$ScriptName][$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

function Write-EnvVar {
    param([string]$Key, [string]$Value)
    Write-Output "$Key=$Value"
}

function Resolve-Variables {
    param(
        [string]$Template,
        [hashtable]$Variables
    )
    
    if ([string]::IsNullOrEmpty($Template)) { return $Template }
    
    $result = $Template
    foreach ($key in $Variables.Keys) {
        $pattern = '\$\{' + [regex]::Escape($key) + '\}'
        $result = $result -replace $pattern, $Variables[$key]
    }
    return $result
}

function Resolve-ObjectVariables {
    param(
        [object]$Object,
        [hashtable]$Variables
    )
    
    if ($null -eq $Object) { return $null }
    
    if ($Object -is [string]) {
        return Resolve-Variables -Template $Object -Variables $Variables
    }
    
    if ($Object -is [array]) {
        return @($Object | ForEach-Object { Resolve-ObjectVariables -Object $_ -Variables $Variables })
    }
    
    if ($Object -is [PSCustomObject]) {
        $result = [PSCustomObject]@{}
        foreach ($prop in $Object.PSObject.Properties) {
            $resolvedValue = Resolve-ObjectVariables -Object $prop.Value -Variables $Variables
            $result | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $resolvedValue
        }
        return $result
    }
    
    return $Object
}

function Get-ComponentsFromCategory {
    param(
        [object]$Components,
        [string]$Category,
        [hashtable]$BaseVariables,
        [object]$Config
    )
    
    $items = $Components.$Category
    if ($null -eq $items -or $items.Count -eq 0) { return @() }
    
    $resolved = @()
    foreach ($component in $items) {
        if ($component.enabled -eq $false) {
            Write-Log "INFO" "  Skipping disabled component: $($component.name)"
            continue
        }
        
        # Variables spécifiques au composant
        $componentVars = $BaseVariables.Clone()
        $componentVars['component.name'] = $component.name
        
        # Résoudre les paramètres de build
        $buildParams = @{}
        if ($component.params) {
            $resolvedParams = Resolve-ObjectVariables -Object $component.params -Variables $componentVars
            foreach ($prop in $resolvedParams.PSObject.Properties) {
                $buildParams[$prop.Name] = $prop.Value
            }
        }
        
        # Résoudre les paramètres de deploy
        $deployParams = @{}
        if ($component.deployParams) {
            $resolvedDeployParams = Resolve-ObjectVariables -Object $component.deployParams -Variables $componentVars
            foreach ($prop in $resolvedDeployParams.PSObject.Properties) {
                $deployParams[$prop.Name] = $prop.Value
            }
        }
        
        # Construire l'objet composant résolu
        $resolvedComponent = [PSCustomObject]@{
            name = $component.name
            category = $Category
            enabled = $true
            build = [PSCustomObject]@{
                script = Resolve-Variables -Template $component.script -Variables $componentVars
                params = $buildParams
            }
            deploy = [PSCustomObject]@{
                script = Resolve-Variables -Template $component.deployScript -Variables $componentVars
                params = $deployParams
            }
        }
        
        $resolved += $resolvedComponent
        Write-Log "INFO" "  Resolved: $($component.name) ($Category)"
    }
    
    return $resolved
}

# =============================================================================
# VALIDATION
# =============================================================================

if (-not (Test-Path $ConfigPath)) {
    Write-Log "ERROR" "Config not found: $ConfigPath"
    exit 1
}

if ([string]::IsNullOrEmpty($Workspace)) {
    $Workspace = (Get-Location).Path
    Write-Log "WARNING" "WORKSPACE not set, using current directory: $Workspace"
}

# Normaliser l'environnement (première lettre majuscule pour les paths Windows)
$EnvDisplay = (Get-Culture).TextInfo.ToTitleCase($Environment.ToLower())

Write-Log "INFO" "Resolving components..."
Write-Log "INFO" "  Config: $ConfigPath"
Write-Log "INFO" "  Environment: $EnvDisplay"
Write-Log "INFO" "  Workspace: $Workspace"

# =============================================================================
# CHARGEMENT CONFIG
# =============================================================================

try {
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Log "ERROR" "Failed to parse config: $($_.Exception.Message)"
    exit 1
}

# Vérifier structure V2
if (-not $config.components) {
    Write-Log "ERROR" "Config does not have 'components' section (V2 structure required)"
    exit 1
}

# =============================================================================
# VARIABLES DE BASE
# =============================================================================

$baseVariables = @{
    'WORKSPACE' = $Workspace
    'environment' = $EnvDisplay
    'server' = $TargetServer
}

# Ajouter variables depuis build.proxy si présentes
if ($config.build.proxy) {
    $baseVariables['proxy.server'] = $config.build.proxy.server
    $baseVariables['proxy.port'] = $config.build.proxy.port
}

# Ajouter defaultBaseFolder et publishFolder
if ($config.build.defaultBaseFolder) {
    $baseVariables['build.baseFolder'] = Resolve-Variables -Template $config.build.defaultBaseFolder -Variables $baseVariables
}
if ($config.build.publishFolder) {
    $baseVariables['build.publishFolder'] = Resolve-Variables -Template $config.build.publishFolder -Variables $baseVariables
}

Write-Log "INFO" "Base variables initialized"

# =============================================================================
# RÉSOLUTION COMPOSANTS
# =============================================================================

$allComponents = @()
$componentCategories = @('apis', 'webApps', 'consoleServices', 'batches', 'angular', 'dbScripts')

foreach ($category in $componentCategories) {
    if ($config.components.$category -and $config.components.$category.Count -gt 0) {
        Write-Log "INFO" "Processing category: $category"
        $categoryComponents = Get-ComponentsFromCategory `
            -Components $config.components `
            -Category $category `
            -BaseVariables $baseVariables `
            -Config $config
        $allComponents += $categoryComponents
    }
}

Write-Log "INFO" "Total components resolved: $($allComponents.Count)"

# =============================================================================
# GÉNÉRATION SUMMARY
# =============================================================================

$summary = [PSCustomObject]@{
    project = $config.project.name
    environment = $EnvDisplay
    workspace = $Workspace
    timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    counts = [PSCustomObject]@{
        total = $allComponents.Count
        apis = ($allComponents | Where-Object { $_.category -eq 'apis' }).Count
        webApps = ($allComponents | Where-Object { $_.category -eq 'webApps' }).Count
        consoleServices = ($allComponents | Where-Object { $_.category -eq 'consoleServices' }).Count
        batches = ($allComponents | Where-Object { $_.category -eq 'batches' }).Count
        angular = ($allComponents | Where-Object { $_.category -eq 'angular' }).Count
        dbScripts = ($allComponents | Where-Object { $_.category -eq 'dbScripts' }).Count
    }
    components = $allComponents
}

# =============================================================================
# OUTPUT
# =============================================================================

# Sortie fichier JSON si demandé
if ($OutputFile) {
    $summary | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Log "SUCCESS" "Components written to: $OutputFile"
}

# Sortie variables environnement
Write-EnvVar "COMPONENTS_TOTAL" $allComponents.Count
Write-EnvVar "COMPONENTS_APIS" ($allComponents | Where-Object { $_.category -eq 'apis' }).Count
Write-EnvVar "COMPONENTS_WEBAPPS" ($allComponents | Where-Object { $_.category -eq 'webApps' }).Count
Write-EnvVar "COMPONENTS_CONSOLE" ($allComponents | Where-Object { $_.category -eq 'consoleServices' }).Count
Write-EnvVar "COMPONENTS_BATCHES" ($allComponents | Where-Object { $_.category -eq 'batches' }).Count
Write-EnvVar "COMPONENTS_ANGULAR" ($allComponents | Where-Object { $_.category -eq 'angular' }).Count
Write-EnvVar "COMPONENTS_DBSCRIPTS" ($allComponents | Where-Object { $_.category -eq 'dbScripts' }).Count

# Liste des noms pour itération Jenkins
$apiNames = ($allComponents | Where-Object { $_.category -eq 'apis' } | ForEach-Object { $_.name }) -join ","
$webAppNames = ($allComponents | Where-Object { $_.category -eq 'webApps' } | ForEach-Object { $_.name }) -join ","
$consoleNames = ($allComponents | Where-Object { $_.category -eq 'consoleServices' } | ForEach-Object { $_.name }) -join ","
$batchNames = ($allComponents | Where-Object { $_.category -eq 'batches' } | ForEach-Object { $_.name }) -join ","
$angularNames = ($allComponents | Where-Object { $_.category -eq 'angular' } | ForEach-Object { $_.name }) -join ","

Write-EnvVar "COMPONENTS_APIS_LIST" $apiNames
Write-EnvVar "COMPONENTS_WEBAPPS_LIST" $webAppNames
Write-EnvVar "COMPONENTS_CONSOLE_LIST" $consoleNames
Write-EnvVar "COMPONENTS_BATCHES_LIST" $batchNames
Write-EnvVar "COMPONENTS_ANGULAR_LIST" $angularNames

Write-Log "SUCCESS" "Component resolution completed"
exit 0