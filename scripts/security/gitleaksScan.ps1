param(
    [Parameter(Mandatory=$true)]
    [string]$repoPath,

    [string]$configFile = "config/gitleaks.toml",
    [string]$reportDir = "gitleaks-report",
    [string]$baselineFile = "",
    [switch]$scanHistory = $false,
    [string]$gitleaksDir = "C:\\tools\\gitleaks"
)

$ErrorActionPreference = "Stop"

Write-Output ""
Write-Output "======================================================"
Write-Output "GITLEAKS SECRET SCANNING"
Write-Output "======================================================"
Write-Output "Repository: $repoPath"
Write-Output "Config: $configFile"
Write-Output "Scan History: $scanHistory"
Write-Output ""

# --- Resolve gitleaks path
$gitleaksExe = Join-Path $gitleaksDir "gitleaks.exe"
if (-not (Test-Path $gitleaksExe)) {
    Write-Error "GitLeaks executable not found: $gitleaksExe"
    Write-Error "Please ensure it is installed in $gitleaksDir"
    exit 1
}

# --- Version
Write-Output "GitLeaks version:"
$gitleaksVersion = & $gitleaksExe version 2>$null
if (-not $gitleaksVersion) { $gitleaksVersion = "(unknown)" }
Write-Output $gitleaksVersion
Write-Output ""

# --- Repo check
if (-not (Test-Path $repoPath)) {
    Write-Error "Repository path not found: $repoPath"
    exit 1
}

# --- Determine branch (handles detached HEAD)
function Get-GitBranch {
    param([string]$path)
    $branch = $null
    Push-Location $path
    try {
        $branch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
        if ([string]::IsNullOrEmpty($branch) -or $branch -eq "HEAD") {
            $desc = (git describe --contains --all HEAD 2>$null)
            if ($desc) { $branch = $desc.Trim() }
            if (-not $branch) { $branch = (git rev-parse --short=8 HEAD 2>$null) }
        }
    } catch { }
    finally { Pop-Location }
    if ([string]::IsNullOrEmpty($branch)) { $branch = "(unknown)" }
    return $branch
}

$branch = Get-GitBranch -path $repoPath

Write-Output "Branch: $branch"
Write-Output ""

# --- Config existence
if ($configFile -and -not (Test-Path $configFile)) {
    Write-Warning "Config file not found: $configFile"
    Write-Output "Using default GitLeaks configuration"
    $configFile = ""
}

# --- Prepare report dir/paths
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$reportJson = Join-Path $reportDir "gitleaks-report.json"
$htmlPath   = Join-Path $reportDir "gitleaks-report.html"
$reportCss  = Join-Path $reportDir "report.css"

# --- Remove previous report(s)
if (Test-Path $reportJson) { Remove-Item $reportJson -Force }
if (Test-Path $htmlPath)   { Remove-Item $htmlPath -Force }
if (Test-Path $reportCss)  { Remove-Item $reportCss -Force }

# --- Build gitleaks args
$gitleaksArgs = @(
    "detect",
    "--source", $repoPath,
    "--report-path", $reportJson,
    "--report-format", "json",
    "--redact"
)
if ($configFile) { $gitleaksArgs += @("--config", $configFile) }

# Baseline (optionnel)
if ($baselineFile -and (Test-Path $baselineFile)) {
    $gitleaksArgs += @("--baseline-path", $baselineFile)
}
if (-not $scanHistory) { $gitleaksArgs += "--no-git" }

Write-Output "======================================================"
Write-Output "EXECUTING SCAN"
Write-Output "======================================================"
Write-Output "Command: $gitleaksExe $($gitleaksArgs -join ' ')"
Write-Output ""

$scanStartTime = Get-Date
& $gitleaksExe @gitleaksArgs
$gitleaksExit = $LASTEXITCODE
$scanDuration = ((Get-Date) - $scanStartTime).TotalSeconds

Write-Output ""
Write-Output "======================================================"
Write-Output "SCAN COMPLETED"
Write-Output "======================================================"
Write-Output "Duration: $([math]::Round($scanDuration, 2))s"
Write-Output "ExitCode: $gitleaksExit"
Write-Output ""

# --- Ensure report exists if leaks were found
if (-not (Test-Path $reportJson)) {
    if ($gitleaksExit -ne 0) {
        Write-Error "Gitleaks failed (exit $gitleaksExit) and no report was produced."
        exit 1
    } else {
        Write-Output "No secrets detected (report file not created)"
        Write-Output "======================================================"
        exit 0
    }
}

# --- Parse JSON
try {
    $reportContent = Get-Content $reportJson -Raw
    $report = $reportContent | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse report JSON: $($_.Exception.Message)"
    exit 1
}
if ($null -eq $report) { $report = @() }
elseif ($report -isnot [System.Collections.IEnumerable]) { $report = @($report) }

# --- Counts/groups
$leaksCount = $report.Count
$leaksByRule = @()
$leaksByFile = @()
if ($leaksCount -gt 0) {
    $leaksByRule = $report | Group-Object -Property RuleID
    $leaksByFile = $report | Group-Object -Property File
}

Write-Output "RESULTS SUMMARY"
Write-Output "======================================================"
Write-Output "Branch: $branch"
Write-Output "Secrets Detected: $leaksCount"
Write-Output ""

if ($leaksCount -eq 0) {
    Write-Output "NO SECRETS FOUND"
    Write-Output "======================================================"
    exit 0
}

Write-Output "SECRETS FOUND - DETAILS:"
Write-Output ""
Write-Output "By Secret Type:"
foreach ($group in $leaksByRule) {
    Write-Output " $($group.Name): $($group.Count)"
}
Write-Output ""
Write-Output "By File:"
foreach ($group in $leaksByFile) {
    Write-Output "  $($group.Name): $($group.Count)"
}
Write-Output ""
Write-Output "Detailed Findings:"
Write-Output "──────────────────────────────────────────────────────"
$findingIndex = 1
foreach ($leak in $report) {
    Write-Output ""
    Write-Output "[$findingIndex] $($leak.Description)"
    Write-Output "  File: $($leak.File)"
    Write-Output "  Line: $($leak.StartLine), Column: $($leak.StartColumn)"
    Write-Output "  Rule: $($leak.RuleID)"
    if ($leak.Commit) {
        Write-Output "  Commit: $($leak.Commit.Substring(0, 8))"
        Write-Output "  Author: $($leak.Author)"
        Write-Output "  Date: $($leak.Date)"
    }
    $secretPreview = $leak.Secret
    if ($secretPreview -and $secretPreview.Length -gt 50) { $secretPreview = $secretPreview.Substring(0, 50) + "..." }
    Write-Output "  Secret: $secretPreview"
    $findingIndex++
}

Write-Output ""
Write-Output "======================================================"

# --- Inject metadata & rewrite JSON
$metadata = [PSCustomObject]@{
    branch   = $branch
    scanMode = $(if($scanHistory) { "Full History" } else { "Current State" })
    date     = (Get-Date)
    leaks    = $report
}
$metadata | ConvertTo-Json -Depth 8 | Out-File -FilePath $reportJson -Encoding UTF8

# --- Write external CSS (CSP-friendly)
$css = @"
body{font-family:'Segoe UI',Arial,sans-serif;margin:0;padding:20px;background:#f5f5f5}
.container{max-width:1400px;margin:0 auto;background:#fff;padding:30px;box-shadow:0 2px 8px rgba(0,0,0,.1);border-radius:8px}
h1{color:#d9534f;border-bottom:3px solid #d9534f;padding-bottom:15px;margin-top:0}
h2{color:#333;margin-top:30px;border-bottom:2px solid #eee;padding-bottom:10px}
.alert{background:#fff3cd;padding:20px;border-left:5px solid #ffc107;margin:20px 0;border-radius:4px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px;margin:30px 0}
.stat{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;padding:25px;border-radius:8px;text-align:center;box-shadow:0 4px 6px rgba(0,0,0,.1)}
.stat-number{font-size:48px;font-weight:bold;margin:10px 0}
.stat-label{font-size:14px;opacity:.9;text-transform:uppercase;letter-spacing:1px}
.leak{border:1px solid #ddd;margin:20px 0;padding:20px;background:#fafafa;border-left:5px solid #d9534f;border-radius:4px}
.leak-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:15px}
.leak-title{font-size:18px;font-weight:bold;color:#d9534f}
.leak-index{background:#d9534f;color:#fff;padding:5px 12px;border-radius:20px;font-size:14px}
.file{color:#06c;font-weight:bold;font-size:14px;margin:8px 0}
.meta{color:#666;font-size:13px;margin:5px 0}
.rule{background:#e3f2fd;color:#1976d2;padding:5px 12px;display:inline-block;border-radius:4px;font-size:12px;margin:8px 0;font-weight:500}
.secret{background:#ffe6e6;padding:15px;font-family:'Courier New',monospace;font-size:13px;overflow-x:auto;margin:15px 0;border:1px solid #ffcccc;border-radius:4px;color:#333}
.footer{margin-top:40px;padding-top:20px;border-top:1px solid #eee;text-align:center;color:#666;font-size:13px}
.icon{font-size:20px;margin-right:8px}
"@
$css | Out-File -FilePath $reportCss -Encoding UTF8

# --- HTML with external stylesheet (no inline <style>)
Add-Type -AssemblyName System.Web
function HtmlEnc([string]$s){ if ($null -eq $s) { return "" } return [System.Web.HttpUtility]::HtmlEncode($s) }

$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>GitLeaks Security Scan Report</title>
    <link rel="stylesheet" href="report.css">
</head>
<body>
    <div class="container">
        <h1><span class="icon">🔐</span>GitLeaks Security Scan Report</h1>
        <div class="alert">
            <strong>⚠️ SECURITY:</strong> $leaksCount secret(s) detected. Rotate credentials and remove from Git history where applicable.
        </div>
        <div class="stats">
            <div class="stat"><div class="stat-label">Total Secrets</div><div class="stat-number">$leaksCount</div></div>
            <div class="stat"><div class="stat-label">Files Affected</div><div class="stat-number">$($leaksByFile.Count)</div></div>
            <div class="stat"><div class="stat-label">Rule Types</div><div class="stat-number">$($leaksByRule.Count)</div></div>
            <div class="stat"><div class="stat-label">Scan Duration</div><div class="stat-number">$([math]::Round($scanDuration, 1))s</div></div>
        </div>
        <p class="meta"><strong>Repository:</strong> $(HtmlEnc $repoPath) |
           <strong>Branch:</strong> $(HtmlEnc $branch) |
           <strong>Scan Mode:</strong> $(if($scanHistory){'Full History'}else{'Current State'})</p>
        <h2>Secrets by Type</h2>
        <ul>
"@

$htmlBody = ""
foreach ($group in $leaksByRule) {
    $htmlBody += "<li><strong>$(HtmlEnc $($group.Name)):</strong> $($group.Count)</li>`n"
}
$htmlBody += @"
        </ul>
        <h2>Detailed Findings</h2>
"@

$findingIndex = 1
foreach ($leak in $report) {
    $secretPreview = $leak.Secret
    if ($secretPreview -and $secretPreview.Length -gt 100) { $secretPreview = $secretPreview.Substring(0, 100) + "..." }
    $secretPreview = HtmlEnc $secretPreview

    $htmlBody += @"
        <div class="leak">
            <div class="leak-header">
                <div class="leak-title">$(HtmlEnc $leak.Description)</div>
                <div class="leak-index">#$findingIndex</div>
            </div>
            <div class="file">📄 $(HtmlEnc $leak.File)</div>
            <div class="meta">Line $($leak.StartLine), Column $($leak.StartColumn)</div>
            <div class="rule">🏷️ $(HtmlEnc $leak.RuleID)</div>
"@
    if ($leak.Commit) {
        $htmlBody += "<div class='meta'><strong>Commit:</strong> $($leak.Commit.Substring(0,8)) | <strong>Author:</strong> $(HtmlEnc $leak.Author) | <strong>Date:</strong> $($leak.Date)</div>`n"
    }
    $htmlBody += "<div class='secret'>$secretPreview</div>`n</div>`n"
    $findingIndex++
}

$htmlFooter = @"
        <div class="footer">
            <p>Generated by GitLeaks on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p>Repository: $(HtmlEnc $repoPath) | Branch: $(HtmlEnc $branch) | Scan Mode: $(if($scanHistory){'Full History'}else{'Current State'})</p>
        </div>
    </div>
</body>
</html>
"@

($htmlHeader + $htmlBody + $htmlFooter) | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Output "CSS file generated: $reportCss"
Write-Output "HTML report generated: $htmlPath"
Write-Output ""
Write-Output "======================================================"
Write-Output "REPORTS GENERATED"
Write-Output "======================================================"
Write-Output "  JSON: $reportJson"
Write-Output "  HTML: $htmlPath"
Write-Output "  CSS : $reportCss"
Write-Output "======================================================"
Write-Output ""

# --- Exit policy: fail build if leaks > 0
if ($leaksCount -gt 0) {
    Write-Output "SECURITY GATE FAILED"
    Write-Output ""
    Write-Output "ACTION REQUIRED:"
    Write-Output "  1. Review detected secrets"
    Write-Output "  2. Rotate compromised credentials immediately"
    Write-Output "  3. Remove secrets from Git history (filter-repo/BFG) if present"
    Write-Output "  4. Move secrets to Jenkins Credentials/KeyVault"
    Write-Output "  5. Add false positives to allowlist (config/gitleaks.toml)"
    Write-Output ""
    exit 1
}

exit 0
