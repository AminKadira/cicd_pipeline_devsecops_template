# ==============================================================================
# Artifact Signing Script
# ==============================================================================
# Description: GPG signature generation for build artifacts
# OWASP Compliance: A08 (Software and Data Integrity Failures)
# SLSA Level 2: Tamper-resistant build provenance
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$ArtifactsPath,
    
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-F0-9]{8,}$')]
    [string]$GpgKeyId,
    
    [Parameter(Mandatory=$true)]
    [string]$GpgPassphrase,
    
    [switch]$VerifyAfterSign,
    
    [ValidateSet("SHA256", "SHA512")]
    [string]$ChecksumAlgorithm = "SHA256"
)

$ErrorActionPreference = "Stop"

Write-Output ""
Write-Output "======================================================"
Write-Output "ARTIFACT SIGNING"
Write-Output "======================================================"
Write-Output "Artifacts Path: $ArtifactsPath"
Write-Output "GPG Key ID: ${GpgKeyId:0:8}********"
Write-Output "Checksum Algorithm: $ChecksumAlgorithm"
Write-Output "Verify After Sign: $VerifyAfterSign"
Write-Output ""

# ==============================================================================
# VALIDATE GPG AVAILABILITY
# ==============================================================================
Write-Output "Validating GPG installation..."

try {
    $gpgVersion = & gpg --version 2>&1 | Select-Object -First 1
    Write-Output "✓ GPG available: $gpgVersion"
} catch {
    Write-Error "GPG not found. Please install GPG and add to PATH."
    exit 1
}

# ==============================================================================
# CONFIGURE GPG FOR NON-INTERACTIVE OPERATION
# ==============================================================================
Write-Output ""
Write-Output "Configuring GPG for batch mode..."

$env:GPG_TTY = "not a tty"

# Create temporary GPG config
$gpgConfigDir = Join-Path $env:TEMP "gpg-$(Get-Random)"
New-Item -ItemType Directory -Path $gpgConfigDir -Force | Out-Null

$env:GNUPGHOME = $gpgConfigDir

# Write GPG agent config
$agentConf = @"
pinentry-mode loopback
allow-loopback-pinentry
"@

$agentConf | Out-File -FilePath (Join-Path $gpgConfigDir "gpg-agent.conf") -Encoding ASCII

Write-Output "✓ GPG configured for batch operations"

# ==============================================================================
# FIND ARTIFACTS TO SIGN
# ==============================================================================
Write-Output ""
Write-Output "Scanning for artifacts..."

$artifactPatterns = @("*.dll", "*.exe", "*.nupkg", "*.jar", "*.zip", "*.tar.gz")
$artifacts = Get-ChildItem -Path $ArtifactsPath -Recurse -Include $artifactPatterns |
    Where-Object { $_.Name -notmatch '\.asc$' }

Write-Output "Found $($artifacts.Count) artifacts to sign"

if ($artifacts.Count -eq 0) {
    Write-Warning "No artifacts found to sign"
    exit 0
}

# ==============================================================================
# SIGN ARTIFACTS
# ==============================================================================
Write-Output ""
Write-Output "======================================================"
Write-Output "SIGNING ARTIFACTS"
Write-Output "======================================================"

$signedCount = 0
$failedCount = 0
$signatureManifest = @()

foreach ($artifact in $artifacts) {
    Write-Output ""
    Write-Output "Signing: $($artifact.Name)"
    
    $signatureFile = "$($artifact.FullName).asc"
    
    # Remove existing signature
    if (Test-Path $signatureFile) {
        Remove-Item $signatureFile -Force
    }
    
    try {
        # Sign artifact with GPG
        $signProcess = Start-Process -FilePath "gpg" -ArgumentList @(
            "--batch",
            "--yes",
            "--pinentry-mode", "loopback",
            "--passphrase", $GpgPassphrase,
            "--local-user", $GpgKeyId,
            "--armor",
            "--detach-sign",
            "--output", $signatureFile,
            $artifact.FullName
        ) -NoNewWindow -Wait -PassThru
        
        if ($signProcess.ExitCode -ne 0) {
            throw "GPG signing failed with exit code: $($signProcess.ExitCode)"
        }
        
        # Verify signature was created
        if (-not (Test-Path $signatureFile)) {
            throw "Signature file not created: $signatureFile"
        }
        
        # Verify signature if requested
        if ($VerifyAfterSign) {
            $verifyProcess = Start-Process -FilePath "gpg" -ArgumentList @(
                "--verify",
                $signatureFile,
                $artifact.FullName
            ) -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\gpg-verify.txt"
            
            if ($verifyProcess.ExitCode -ne 0) {
                $verifyError = Get-Content "$env:TEMP\gpg-verify.txt" -Raw
                throw "Signature verification failed: $verifyError"
            }
            
            Write-Output "  ✓ Signature verified"
        }
        
        # Generate checksum
        $checksum = (Get-FileHash -Path $artifact.FullName -Algorithm $ChecksumAlgorithm).Hash
        
        # Add to manifest
        $signatureManifest += @{
            file = $artifact.Name
            path = $artifact.FullName.Replace($ArtifactsPath, ".")
            size = $artifact.Length
            checksum = $checksum
            checksumAlgorithm = $ChecksumAlgorithm
            signature = "$($artifact.Name).asc"
            signedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
        Write-Output "  ✓ Signed successfully"
        Write-Output "  Checksum ($ChecksumAlgorithm): $checksum"
        
        $signedCount++
        
    } catch {
        Write-Error "  ✗ Failed to sign: $($_.Exception.Message)"
        $failedCount++
    }
}

# ==============================================================================
# GENERATE SIGNATURE MANIFEST
# ==============================================================================
Write-Output ""
Write-Output "======================================================"
Write-Output "GENERATING SIGNATURE MANIFEST"
Write-Output "======================================================"

$manifestData = @{
    version = "2.0.0"
    generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    gpgKeyId = $GpgKeyId
    checksumAlgorithm = $ChecksumAlgorithm
    totalArtifacts = $artifacts.Count
    signedArtifacts = $signedCount
    failedArtifacts = $failedCount
    artifacts = $signatureManifest
}

$manifestFile = Join-Path $ArtifactsPath "signatures.manifest.json"
$manifestData | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestFile -Encoding UTF8

Write-Output "✓ Manifest generated: signatures.manifest.json"

# Sign the manifest itself
Write-Output ""
Write-Output "Signing manifest..."

$manifestSigFile = "$manifestFile.asc"

if (Test-Path $manifestSigFile) {
    Remove-Item $manifestSigFile -Force
}

try {
    $signProcess = Start-Process -FilePath "gpg" -ArgumentList @(
        "--batch",
        "--yes",
        "--pinentry-mode", "loopback",
        "--passphrase", $GpgPassphrase,
        "--local-user", $GpgKeyId,
        "--clearsign",
        "--output", $manifestSigFile,
        $manifestFile
    ) -NoNewWindow -Wait -PassThru
    
    if ($signProcess.ExitCode -eq 0) {
        Write-Output "✓ Manifest signed"
    } else {
        throw "Failed to sign manifest"
    }
} catch {
    Write-Warning "Failed to sign manifest: $($_.Exception.Message)"
}

# ==============================================================================
# CLEANUP
# ==============================================================================
Write-Output ""
Write-Output "Cleaning up GPG environment..."

# Remove GPG home directory
if (Test-Path $gpgConfigDir) {
    Remove-Item -Path $gpgConfigDir -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -Path "$env:TEMP\gpg-verify.txt" -Force -ErrorAction SilentlyContinue

# ==============================================================================
# SUMMARY
# ==============================================================================
Write-Output ""
Write-Output "======================================================"
Write-Output "SIGNING COMPLETED"
Write-Output "======================================================"
Write-Output "Total Artifacts: $($artifacts.Count)"
Write-Output "Successfully Signed: $signedCount"
Write-Output "Failed: $failedCount"
Write-Output "Manifest: $manifestFile"
Write-Output "======================================================"
Write-Output ""

# Exit with appropriate code
if ($failedCount -gt 0) {
    Write-Error "Some artifacts failed to sign"
    exit 1
} else {
    Write-Output "✅ All artifacts signed successfully"
    exit 0
}