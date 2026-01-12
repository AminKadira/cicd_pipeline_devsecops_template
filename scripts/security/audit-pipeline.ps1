# ==============================================================================
# Pipeline Security Audit Script
# ==============================================================================
# Description: Self-audit framework for security compliance
# OWASP Compliance: A05 (Security Misconfiguration), A09 (Security Logging)
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$WorkspaceDir,
    
    [Parameter(Mandatory=$true)]
    [string]$ReportDir,
    
    [switch]$StrictMode
)

$ErrorActionPreference = "Stop"

Write-Output ""
Write-Output "======================================================"
Write-Output "PIPELINE SECURITY AUDIT"
Write-Output "======================================================"
Write-Output "Workspace: $WorkspaceDir"
Write-Output "Report Dir: $ReportDir"
Write-Output "Strict Mode: $StrictMode"
Write-Output ""

# Create report directory
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

# Initialize audit results
$auditResults = @{
    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    version = "2.0.0"
    workspace = $WorkspaceDir
    checks = @{}
    findings = @()
    status = "PASS"
}

# ==============================================================================
# CHECK 1: SCAN FOR HARDCODED SECRETS
# ==============================================================================
Write-Output "======================================================"
Write-Output "CHECK 1: SCANNING FOR HARDCODED SECRETS"
Write-Output "======================================================"

$secretPatterns = @(
    'password\s*=\s*[''"]',
    'token\s*=\s*[''"]',
    'api[_-]?key\s*=\s*[''"]',
    'secret\s*=\s*[''"]',
    'private[_-]?key\s*=\s*[''"]',
    'aws[_-]?access[_-]?key',
    'AKIA[0-9A-Z]{16}',  # AWS Access Key
    'ghp_[0-9a-zA-Z]{36}',  # GitHub Token
    'sk-[0-9a-zA-Z]{48}',  # OpenAI API Key
    'Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*'  # Bearer tokens
)

$secretFindings = @()

Get-ChildItem -Path $WorkspaceDir -Recurse -File -Include "*.groovy","*.ps1","*.json","*.yml","*.yaml" |
    Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.git\\' } |
    ForEach-Object {
        $file = $_
        $content = Get-Content $file.FullName -Raw
        
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern) {
                $secretFindings += @{
                    file = $file.FullName.Replace($WorkspaceDir, ".")
                    pattern = $pattern
                    line = ($content -split "`n" | Select-String -Pattern $pattern | Select-Object -First 1).LineNumber
                }
            }
        }
    }

$auditResults.checks.secretScan = @{
    patterns = $secretPatterns.Count
    filesScanned = (Get-ChildItem -Path $WorkspaceDir -Recurse -File).Count
    findings = $secretFindings.Count
    details = $secretFindings
}

if ($secretFindings.Count -gt 0) {
    Write-Output "⚠️  SECRETS DETECTED: $($secretFindings.Count)"
    $secretFindings | ForEach-Object {
        Write-Output "  - $($_.file):$($_.line) → $($_.pattern)"
    }
    $auditResults.status = "FAIL"
    $auditResults.findings += "Hardcoded secrets detected"
} else {
    Write-Output "✓ No hardcoded secrets detected"
}

Write-Output ""

# ==============================================================================
# CHECK 2: VALIDATE FILE PERMISSIONS
# ==============================================================================
Write-Output "======================================================"
Write-Output "CHECK 2: VALIDATING FILE PERMISSIONS"
Write-Output "======================================================"

$sensitiveFiles = @(
    "config/security-gates.json",
    "config/security-hardening.json",
    "scripts/security/*.ps1"
)

$permissionIssues = @()

foreach ($pattern in $sensitiveFiles) {
    $files = Get-ChildItem -Path (Join-Path $WorkspaceDir $pattern) -ErrorAction SilentlyContinue
    
    foreach ($file in $files) {
        $acl = Get-Acl $file.FullName
        
        # Check if file is world-readable (not applicable on Windows, but check group permissions)
        $everyoneAccess = $acl.Access | Where-Object { $_.IdentityReference -eq "Everyone" }
        
        if ($everyoneAccess) {
            $permissionIssues += @{
                file = $file.FullName.Replace($WorkspaceDir, ".")
                issue = "File accessible to Everyone group"
            }
        }
    }
}

$auditResults.checks.permissions = @{
    filesChecked = $sensitiveFiles.Count
    issues = $permissionIssues.Count
    details = $permissionIssues
}

if ($permissionIssues.Count -gt 0) {
    Write-Output "⚠️  PERMISSION ISSUES: $($permissionIssues.Count)"
    if ($StrictMode) {
        $auditResults.status = "FAIL"
        $auditResults.findings += "Insecure file permissions"
    }
} else {
    Write-Output "✓ File permissions OK"
}

Write-Output ""

# ==============================================================================
# CHECK 3: VALIDATE SECURITY CONFIGURATIONS
# ==============================================================================
Write-Output "======================================================"
Write-Output "CHECK 3: VALIDATING SECURITY CONFIGURATIONS"
Write-Output "======================================================"

$configChecks = @()

# Check security-gates.json
$gatesFile = Join-Path $WorkspaceDir "config/security-gates.json"
if (Test-Path $gatesFile) {
    try {
        $gates = Get-Content $gatesFile | ConvertFrom-Json
        
        # Validate critical gates are enabled
        $requiredGates = @("secrets", "cvss_critical", "cvss_high")
        
        foreach ($gate in $requiredGates) {
            if (-not $gates.gates.$gate) {
                $configChecks += @{
                    file = "security-gates.json"
                    issue = "Missing required gate: $gate"
                }
            } elseif ($gates.gates.$gate.action -ne "BLOCK") {
                $configChecks += @{
                    file = "security-gates.json"
                    issue = "Gate '$gate' should BLOCK, not $($gates.gates.$gate.action)"
                }
            }
        }
        
        Write-Output "✓ Security gates configuration validated"
        
    } catch {
        $configChecks += @{
            file = "security-gates.json"
            issue = "Failed to parse: $($_.Exception.Message)"
        }
    }
} else {
    $configChecks += @{
        file = "security-gates.json"
        issue = "File not found"
    }
}

# Check security-hardening.json
$hardeningFile = Join-Path $WorkspaceDir "config/security-hardening.json"
if (Test-Path $hardeningFile) {
    try {
        $hardening = Get-Content $hardeningFile | ConvertFrom-Json
        
        # Validate critical settings
        if (-not $hardening.secrets.blockOnDetection) {
            $configChecks += @{
                file = "security-hardening.json"
                issue = "secrets.blockOnDetection should be true"
            }
        }
        
        if (-not $hardening.network.requireTLS) {
            $configChecks += @{
                file = "security-hardening.json"
                issue = "network.requireTLS should be true"
            }
        }
        
        Write-Output "✓ Security hardening configuration validated"
        
    } catch {
        $configChecks += @{
            file = "security-hardening.json"
            issue = "Failed to parse: $($_.Exception.Message)"
        }
    }
} else {
    $configChecks += @{
        file = "security-hardening.json"
        issue = "File not found"
    }
}

$auditResults.checks.configurations = @{
    issues = $configChecks.Count
    details = $configChecks
}

if ($configChecks.Count -gt 0) {
    Write-Output "⚠️  CONFIGURATION ISSUES: $($configChecks.Count)"
    $auditResults.status = "FAIL"
    $auditResults.findings += "Security configuration issues"
} else {
    Write-Output "✓ All security configurations valid"
}

Write-Output ""

# ==============================================================================
# CHECK 4: VERIFY ARTIFACT SIGNATURES (if enabled)
# ==============================================================================
Write-Output "======================================================"
Write-Output "CHECK 4: VERIFYING ARTIFACT SIGNATURES"
Write-Output "======================================================"

$publishDir = Join-Path $WorkspaceDir "project/publish"
$signatureChecks = @()

if (Test-Path $publishDir) {
    $artifacts = Get-ChildItem -Path $publishDir -Recurse -Include "*.dll","*.exe","*.nupkg" -ErrorAction SilentlyContinue
    
    foreach ($artifact in $artifacts) {
        $sigFile = "$($artifact.FullName).asc"
        
        if (-not (Test-Path $sigFile)) {
            $signatureChecks += @{
                artifact = $artifact.FullName.Replace($WorkspaceDir, ".")
                issue = "Missing signature file"
            }
        } else {
            # Verify signature (requires GPG)
            try {
                $verifyResult = & gpg --verify $sigFile $artifact.FullName 2>&1
                
                if ($LASTEXITCODE -ne 0) {
                    $signatureChecks += @{
                        artifact = $artifact.FullName.Replace($WorkspaceDir, ".")
                        issue = "Signature verification failed"
                    }
                }
            } catch {
                $signatureChecks += @{
                    artifact = $artifact.FullName.Replace($WorkspaceDir, ".")
                    issue = "GPG not available for verification"
                }
            }
        }
    }
    
    $auditResults.checks.signatures = @{
        artifactsChecked = $artifacts.Count
        issues = $signatureChecks.Count
        details = $signatureChecks
    }
    
    if ($signatureChecks.Count -gt 0) {
        Write-Output "⚠️  SIGNATURE ISSUES: $($signatureChecks.Count)"
        if ($StrictMode) {
            $auditResults.status = "FAIL"
            $auditResults.findings += "Artifact signature issues"
        }
    } else {
        Write-Output "✓ All artifacts properly signed"
    }
} else {
    Write-Output "ℹ️  No artifacts found for signature verification"
}

Write-Output ""

# ==============================================================================
# GENERATE AUDIT REPORT
# ==============================================================================
Write-Output "======================================================"
Write-Output "GENERATING AUDIT REPORT"
Write-Output "======================================================"

$timestamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
$reportFile = Join-Path $ReportDir "audit-$timestamp.json"

$auditResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportFile -Encoding UTF8

Write-Output ""
Write-Output "======================================================"
Write-Output "AUDIT COMPLETED"
Write-Output "======================================================"
Write-Output "Status: $($auditResults.status)"
Write-Output "Total Findings: $($auditResults.findings.Count)"
Write-Output "Report: $reportFile"
Write-Output "======================================================"
Write-Output ""

# Exit with appropriate code
if ($auditResults.status -eq "FAIL") {
    Write-Output "❌ AUDIT FAILED - Review findings and remediate"
    exit 1
} else {
    Write-Output "✅ AUDIT PASSED - No critical issues detected"
    exit 0
}