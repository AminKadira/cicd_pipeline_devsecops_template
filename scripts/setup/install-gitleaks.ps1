# Script d'installation GitLeaks
$ErrorActionPreference = "Stop"

Write-Output ""
Write-Output "======================================================"
Write-Output "GITLEAKS INSTALLATION"
Write-Output "======================================================"
Write-Output ""

# Configuration
$version = "8.21.2"
$installDir = "C:\tools\gitleaks"
$downloadUrl = "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_windows_x64.zip"

Write-Output "Version: $version"
Write-Output "Install Directory: $installDir"
Write-Output ""

# Créer dossiers
Write-Output "Creating directories..."
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null

# Télécharger GitLeaks
Write-Output "Downloading GitLeaks from GitHub..."
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile "C:\temp\gitleaks.zip" -UseBasicParsing
    Write-Output "✓ Download completed"
}
catch {
    Write-Error "Failed to download GitLeaks: $($_.Exception.Message)"
    exit 1
}

# Extraire
Write-Output ""
Write-Output "Extracting archive..."
try {
    Expand-Archive -Path "C:\temp\gitleaks.zip" -DestinationPath $installDir -Force
    Write-Output "✓ Extraction completed"
}
catch {
    Write-Error "Failed to extract: $($_.Exception.Message)"
    exit 1
}

# Vérifier binaire
if (-not (Test-Path "$installDir\gitleaks.exe")) {
    Write-Error "gitleaks.exe not found after extraction"
    exit 1
}

# Ajouter au PATH (si pas déjà présent)
Write-Output ""
Write-Output "Configuring PATH..."
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")

if ($currentPath -notlike "*$installDir*") {
    $newPath = "$currentPath;$installDir"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    $env:Path = $newPath
    Write-Output "✓ PATH updated"
} else {
    Write-Output "✓ PATH already configured"
}

# Vérifier installation
Write-Output ""
Write-Output "Verifying installation..."
try {
    $versionOutput = & "$installDir\gitleaks.exe" version
    Write-Output "✓ GitLeaks installed successfully"
    Write-Output ""
    Write-Output $versionOutput
}
catch {
    Write-Error "Installation verification failed"
    exit 1
}

# Nettoyer
Write-Output ""
Write-Output "Cleaning up..."
Remove-Item "C:\temp\gitleaks.zip" -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "======================================================"
Write-Output "INSTALLATION COMPLETED"
Write-Output "======================================================"
Write-Output ""
Write-Output "GitLeaks is installed at: $installDir"
Write-Output "Executable: $installDir\gitleaks.exe"
Write-Output ""
Write-Output "Test command:"
Write-Output "  gitleaks version"
Write-Output ""
Write-Output "======================================================"

exit 0