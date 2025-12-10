param(
    [string]$ConfigPath = "config/gitleaks.toml",
    [string]$FixturesDir = "tests/gitleaks/fixtures",
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

function Invoke-Gitleaks {
    param(
        [string]$TargetPath,
        [string]$ConfigPath
    )
    $args = @(
        "detect",
        "--no-git",
        "--config=$ConfigPath",
        "--source=$TargetPath",
        "--report-format=json",
        "--report-path=-"
    )
    $process = Start-Process -FilePath "gitleaks" -ArgumentList $args -NoNewWindow -PassThru -Wait -RedirectStandardOutput "STDOUT.json" -RedirectStandardError "STDERR.txt"
    $stdout = Get-Content -Raw "STDOUT.json"
    $stderr = if (Test-Path "STDERR.txt") { Get-Content -Raw "STDERR.txt" } else { "" }
    Remove-Item -ErrorAction SilentlyContinue "STDOUT.json","STDERR.txt"
    return @{ stdout=$stdout; stderr=$stderr; exitCode=$process.ExitCode }
}

function Assert-Detections {
    param(
        [string]$Path,
        [bool]$ShouldDetect
    )
    $result = Invoke-Gitleaks -TargetPath $Path -ConfigPath $ConfigPath
    if ($VerboseOutput) {
        Write-Host "STDERR:" $result.stderr
        Write-Host "STDOUT:" $result.stdout
    }
    $findings = @()
    if ($result.stdout -and $result.stdout.Trim().StartsWith("{")) {
        try { $json = $result.stdout | ConvertFrom-Json } catch { $json = $null }
        if ($json -and $json.findings) { $findings = $json.findings }
    }
    $detected = ($findings.Count -gt 0)

    if ($ShouldDetect -and -not $detected) {
        Write-Error "Attendu: DETECTION sur $Path, trouvé: 0"
    }
    if (-not $ShouldDetect -and $detected) {
        Write-Error "Attendu: AUCUNE détection sur $Path, trouvé: $($findings.Count)"
    }
}

# Exécution
$positive = Join-Path $FixturesDir "positive"
$negative = Join-Path $FixturesDir "negative"

if (!(Test-Path $positive)) { throw "Fixtures positives introuvables: $positive" }
if (!(Test-Path $negative)) { throw "Fixtures négatives introuvables: $negative" }

Get-ChildItem -Path $positive -File -Recurse | ForEach-Object {
    Write-Host "Test positif:" $_.FullName
    Assert-Detections -Path $_.FullName -ShouldDetect $true
}

Get-ChildItem -Path $negative -File -Recurse | ForEach-Object {
    Write-Host "Test négatif:" $_.FullName
    Assert-Detections -Path $_.FullName -ShouldDetect $false
}

Write-Host "Tests Gitleaks terminés avec succès."
