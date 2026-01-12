# Sur vm011 (Admin PowerShell)
param(
    [string]$ProxyAddress = "proxy.fr.laridak.tools",
    [int]$ProxyPort = 3128
)
# Version à installer
$version = "8.18.4"  # Vérifier dernière sur GitHub
# URL téléchargement (Windows 64-bit)
$downloadUrl = "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_windows_x64.zip"
# Créer dossier
New-Item -ItemType Directory -Path "C:\tools\gitleaks" -Force
New-Item -ItemType Directory -Path "C:\tools\temp" -Force
# Télécharger
Write-Output "Downloading GitLeaks v$version..."

# Forcer TLS 1.2 (résout erreurs SSL/TLS sur environnements anciens)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell' }

$zipPath = "C:\tools\temp\gitleaks.zip"

# Vérifier si déjà téléchargé et valide (> 1 Ko)
$needDownload = $true
if (Test-Path -Path $zipPath) {
    try { $existing = Get-Item $zipPath } catch { $existing = $null }
    if ($existing -and $existing.Length -gt 1024) {
        Write-Output "Archive déjà présente, téléchargement ignoré"
        $needDownload = $false
    } else {
        # Supprimer un fichier partiel/corrompu
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }
}

$invokeParams = @{ Uri = $downloadUrl; OutFile = $zipPath; Headers = $headers; UseBasicParsing = $true }
if (![string]::IsNullOrWhiteSpace($ProxyAddress) -and $ProxyPort -gt 0) {
    $proxyUrl = "http://${ProxyAddress}:${ProxyPort}"
    $invokeParams["Proxy"] = $proxyUrl
    $invokeParams["ProxyUseDefaultCredentials"] = $true
}

if ($needDownload) {
    Invoke-WebRequest @invokeParams
    Write-Output "Download complete"
} else {
    Write-Output "Using existing file: $zipPath"
}
