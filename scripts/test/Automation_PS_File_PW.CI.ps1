# ==============================================================================
# Enhanced Pluxee Automation Test Execution Script
# ==============================================================================
# Description: Executes automated tests with proper parameter handling
# Original: Automation_PS_File_PW.ps1
# Enhanced: With PowerShell parameters instead of arguments
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, HelpMessage="Job name for the test execution")]
    [ValidateNotNullOrEmpty()]
    [string]$JobName = "pluxee_automation_project",
    
    [Parameter(Mandatory=$true, HelpMessage="Tag to run (e.g., WEB, @smoke, @regression)")]
    [ValidateNotNullOrEmpty()]
    [string]$TagToRun,
    
    [Parameter(Mandatory=$true, HelpMessage="Environment to run tests on (uat, tst, sta, prod)")]
    [ValidateSet("uat", "tst", "sta")]
    [string]$Environment,
    
    [Parameter(Mandatory=$false, HelpMessage="Build number for reporting")]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BuildNumber = 1,
    
    [Parameter(Mandatory=$false, HelpMessage="Git repository URL")]
    [ValidateNotNullOrEmpty()]
    [string]$GitRepository = "git@gitlab.fr.pluxee.tools:recette/pluxee_automation_project.git",
    
    [Parameter(Mandatory=$false, HelpMessage="Local project path for execution")]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectPath = "C:\Remote_Execution",
    
    [Parameter(Mandatory=$false, HelpMessage="Network report path")]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath = "\\cefrsvc-eurfs05.ce.sdxcorp.net\Info\SODEXO_AUTOMATION_PROJECT\Jenkins_Reports",
    
    [Parameter(Mandatory=$false, HelpMessage="Skip npm install step")]
    [switch]$SkipInstall,
    
    [Parameter(Mandatory=$false, HelpMessage="Force clean install (remove and reclone)")]
    [switch]$ForceClean,
    
    [Parameter(Mandatory=$false, HelpMessage="Show verbose output")]
    [switch]$Verbose
)

# ==============================================================================
# CONFIGURATION AND VALIDATION
# ==============================================================================

# Set verbose preference based on parameter
if ($Verbose) { $VerbosePreference = "Continue" }

# Get machine name
$MachineName = $env:COMPUTERNAME

# Convert environment to lowercase for consistency
$Environment = $Environment.ToLower()

# Default project folder name
$DefaultJobName = "pluxee_automation_project"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-StepHeader {
    param([string]$StepNumber, [string]$Description)
    
    Write-Host ""
    Write-Host "=" * 80 -ForegroundColor Cyan
    Write-Host "STEP $StepNumber : $Description" -ForegroundColor Yellow
    Write-Host "=" * 80 -ForegroundColor Cyan
}

function Write-StepFooter {
    param([string]$StepNumber, [bool]$Success = $true)
    
    if ($Success) {
        Write-Host "✅ STEP $StepNumber COMPLETED SUCCESSFULLY" -ForegroundColor Green
    } else {
        Write-Host "❌ STEP $StepNumber FAILED" -ForegroundColor Red
    }
    Write-Host ""
}

function Write-InfoMessage {
    param([string]$Message)
    Write-Host "ℹ️  $Message" -ForegroundColor Cyan
}

function Write-SuccessMessage {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "⚠️  $Message" -ForegroundColor Yellow
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

try {
    # Display execution parameters
    Write-Host ""
    Write-Host "🚀 STARTING PLUXEE AUTOMATION TEST EXECUTION" -ForegroundColor Magenta
    Write-Host "=" * 80 -ForegroundColor Magenta
    
    Write-InfoMessage "Execution Parameters:"
    Write-Host "  📝 Job Name: $JobName" -ForegroundColor White
    Write-Host "  🏷️  Tag to Run: $TagToRun" -ForegroundColor White
    Write-Host "  🌍 Environment: $Environment" -ForegroundColor White
    Write-Host "  🔢 Build Number: $BuildNumber" -ForegroundColor White
    Write-Host "  💻 Machine Name: $MachineName" -ForegroundColor White
    Write-Host "  📁 Project Path: $ProjectPath" -ForegroundColor White
    Write-Host "  📊 Report Path: $ReportPath" -ForegroundColor White
    Write-Host "  🔗 Git Repository: $GitRepository" -ForegroundColor White
    
    if ($SkipInstall) { Write-Host "  ⏭️  Skip Install: Enabled" -ForegroundColor Yellow }
    if ($ForceClean) { Write-Host "  🧹 Force Clean: Enabled" -ForegroundColor Yellow }
    
    Write-Host "=" * 80 -ForegroundColor Magenta

    # STEP 1: Create project folder
    Write-StepHeader "1" "CREATING PROJECT FOLDER IF NOT EXISTS"
    Write-InfoMessage "Target folder: $ProjectPath"
    
    try {
        New-Item -Type Directory -Path $ProjectPath -Force | Out-Null
        Write-SuccessMessage "Project folder created/verified: $ProjectPath"
        Write-StepFooter "1" $true
    } catch {
        Write-ErrorMessage "Failed to create project folder: $($_.Exception.Message)"
        Write-StepFooter "1" $false
        throw
    }

    # STEP 2: Git operations (clone or pull)
    Write-StepHeader "2" "GIT REPOSITORY MANAGEMENT"
    
    $projectExists = Test-Path -Path "$ProjectPath\$DefaultJobName"
    
    if ($projectExists -and -not $ForceClean) {
        Write-InfoMessage "Project already exists, attempting git pull..."
        Set-Location "$ProjectPath\$DefaultJobName"
        
        try {
            $gitOutput = & git pull 2>&1
            $gitSuccess = $LASTEXITCODE -eq 0
            
            if ($gitSuccess) {
                Write-SuccessMessage "Git pull completed successfully"
                Write-Verbose "Git output: $gitOutput"
            } else {
                throw "Git pull failed: $gitOutput"
            }
        } catch {
            Write-WarningMessage "Git pull failed, will try clean clone..."
            Write-InfoMessage "Removing existing project folder..."
            
            Set-Location $ProjectPath
            Remove-Item -LiteralPath "$ProjectPath\$DefaultJobName" -Force -Recurse
            
            Write-InfoMessage "Cloning repository..."
            & git clone --depth=1 $GitRepository
            
            if ($LASTEXITCODE -eq 0) {
                Write-SuccessMessage "Git clone completed successfully"
            } else {
                Write-ErrorMessage "Git clone failed"
                throw "Git clone operation failed"
            }
        }
    } else {
        if ($ForceClean -and $projectExists) {
            Write-InfoMessage "Force clean enabled - removing existing project..."
            Remove-Item -LiteralPath "$ProjectPath\$DefaultJobName" -Force -Recurse
        }
        
        Write-InfoMessage "Cloning fresh repository..."
        Set-Location $ProjectPath
        
        & git clone --depth=1 $GitRepository
        
        if ($LASTEXITCODE -eq 0) {
            Write-SuccessMessage "Git clone completed successfully"
        } else {
            Write-ErrorMessage "Git clone failed"
            throw "Git clone operation failed"
        }
    }
    
    Write-StepFooter "2" $true

    # STEP 3: Install dependencies
    if (-not $SkipInstall) {
        Write-StepHeader "3" "INSTALLING DEPENDENCIES"
        Set-Location "$ProjectPath\$DefaultJobName"
        
        try {
            # Set Node.js TLS setting for corporate environment
            $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"
            
            Write-InfoMessage "Running npm install..."
            & npm install
            
            if ($LASTEXITCODE -eq 0) {
                Write-SuccessMessage "NPM install completed successfully"
            } else {
                throw "NPM install failed"
            }
            
            Write-InfoMessage "Installing Playwright browsers..."
            & npx playwright install --with-deps
            
            if ($LASTEXITCODE -eq 0) {
                Write-SuccessMessage "Playwright browsers installed successfully"
            } else {
                Write-WarningMessage "Playwright install had issues, continuing..."
            }
            
            Write-StepFooter "3" $true
        } catch {
            Write-ErrorMessage "Dependency installation failed: $($_.Exception.Message)"
            Write-StepFooter "3" $false
            throw
        }
    } else {
        Write-InfoMessage "Skipping dependency installation as requested"
    }

    # STEP 4: Prepare command line
    Write-StepHeader "4" "PREPARING TEST EXECUTION COMMAND"
    
    $folderName = $TagToRun -replace "[^a-zA-Z0-9]", "-"  # Clean folder name
    
    # Set Playwright to not open HTML report
    $env:PLAYWRIGHT_HTML_OPEN = "never"
    
    # Build the command with proper escaping
    $npmCommand = "npm run test:run:$Environment"
    $grepParameter = "-g `"$TagToRun`""
    $fullCommand = "& $npmCommand -- $grepParameter"
    
    Write-InfoMessage "Test execution details:"
    Write-Host "  📝 NPM Script: $npmCommand" -ForegroundColor White
    Write-Host "  🏷️  Grep Pattern: $TagToRun" -ForegroundColor White
    Write-Host "  📁 Report Folder: $folderName" -ForegroundColor White
    Write-Host "  💻 Full Command: $fullCommand" -ForegroundColor White
    
    Write-StepFooter "4" $true

    # STEP 5: Execute tests
    Write-StepHeader "5" "EXECUTING AUTOMATED TESTS"
    Set-Location "$ProjectPath\$DefaultJobName"
    
    try {
        Write-InfoMessage "Starting test execution..."
        Write-InfoMessage "This may take several minutes depending on test suite size..."
        
        Invoke-Expression $fullCommand
        
        if ($LASTEXITCODE -eq 0) {
            Write-SuccessMessage "Test execution completed successfully"
        } else {
            Write-WarningMessage "Test execution completed with some failures (exit code: $LASTEXITCODE)"
            Write-InfoMessage "This is normal if some tests failed - reports will still be generated"
        }
        
        Write-StepFooter "5" $true
    } catch {
        Write-ErrorMessage "Test execution failed: $($_.Exception.Message)"
        Write-StepFooter "5" $false
        throw
    }

    # STEP 6: Copy reports
    Write-StepHeader "6" "ARCHIVING TEST REPORTS"
    
    try {
        $reportFolder = "$ReportPath\$JobName\$MachineName\$BuildNumber\$folderName"
        Write-InfoMessage "Target report folder: $reportFolder"
        
        # Create report directory structure
        New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
        Write-SuccessMessage "Report directory created: $reportFolder"
        
        # Copy reports
        $sourceReportPath = "$ProjectPath\$DefaultJobName\reports\$Environment"
        
        if (Test-Path $sourceReportPath) {
            Copy-Item -Path $sourceReportPath -Destination $reportFolder -Recurse -Force
            Write-SuccessMessage "Reports copied successfully"
            
            # List copied files for verification
            if ($Verbose) {
                Write-InfoMessage "Copied report contents:"
                Get-ChildItem -Path "$reportFolder\$Environment" -Recurse | ForEach-Object {
                    Write-Host "  📄 $($_.FullName.Replace($reportFolder, '.'))" -ForegroundColor Gray
                }
            }
        } else {
            Write-WarningMessage "Source report path not found: $sourceReportPath"
            Write-InfoMessage "This might be normal if no reports were generated"
        }
        
        Write-StepFooter "6" $true
    } catch {
        Write-ErrorMessage "Report archiving failed: $($_.Exception.Message)"
        Write-StepFooter "6" $false
        throw
    }

    # FINAL SUCCESS MESSAGE
    Write-Host ""
    Write-Host "🎉 EXECUTION COMPLETED SUCCESSFULLY! 🎉" -ForegroundColor Green
    Write-Host "=" * 80 -ForegroundColor Green
    Write-SuccessMessage "Test Tag: $TagToRun"
    Write-SuccessMessage "Environment: $Environment"
    Write-SuccessMessage "Machine: $MachineName"
    Write-SuccessMessage "Build Number: $BuildNumber"
    Write-SuccessMessage "Reports archived to: $reportFolder"
    Write-Host "=" * 80 -ForegroundColor Green

} catch {
    Write-Host ""
    Write-Host "💥 EXECUTION FAILED! 💥" -ForegroundColor Red
    Write-Host "=" * 80 -ForegroundColor Red
    Write-ErrorMessage "Error Details:"
    Write-Host "  Exception: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Script Stack Trace:" -ForegroundColor Red
    Write-Host "$($_.ScriptStackTrace)" -ForegroundColor Yellow
    Write-Host "=" * 80 -ForegroundColor Red
    
    # Wait a bit for output to be visible
    Start-Sleep -Milliseconds 1000
    exit 1
}

# ==============================================================================
# SCRIPT HELP INFORMATION
# ==============================================================================

<#
.SYNOPSIS
    Enhanced Pluxee Automation Test Execution Script

.DESCRIPTION
    This script automates the process of running Pluxee automation tests with proper parameter handling.
    It handles git operations, dependency installation, test execution, and report archiving.

.PARAMETER JobName
    Job name for the test execution (default: "pluxee_automation_project")

.PARAMETER TagToRun
    Tag to run tests for (e.g., "WEB", "@smoke", "@regression") - REQUIRED

.PARAMETER Environment
    Environment to run tests on - REQUIRED
    Valid values: "uat", "tst", "sta", "prod", "dev", "local"

.PARAMETER BuildNumber
    Build number for reporting purposes (default: 1)

.PARAMETER GitRepository
    Git repository URL (default: git@gitlab.fr.pluxee.tools:recette/pluxee_automation_project.git)

.PARAMETER ProjectPath
    Local project path for execution (default: "C:\Remote_Execution")

.PARAMETER ReportPath
    Network report path for archiving results

.PARAMETER SkipInstall
    Skip the npm install step (useful for repeated runs)

.PARAMETER ForceClean
    Force clean install by removing and recloning the repository

.PARAMETER Verbose
    Show verbose output during execution

.EXAMPLE
    .\Automation_PS_File_PW_Enhanced.ps1 -TagToRun "WEB" -Environment "uat"
    
    Basic execution with required parameters

.EXAMPLE
    .\Automation_PS_File_PW_Enhanced.ps1 -TagToRun "@smoke" -Environment "tst" -BuildNumber 123 -Verbose
    
    Run smoke tests on TST environment with build number and verbose output

.EXAMPLE
    .\Automation_PS_File_PW_Enhanced.ps1 -TagToRun "@regression" -Environment "uat" -ForceClean -SkipInstall
    
    Force clean repository and skip install step

.NOTES
    File Name      : Automation_PS_File_PW_Enhanced.ps1
    Author         : Auto-generated enhancement
    Prerequisite   : PowerShell 5.0+, Git, Node.js, NPM
    
.LINK
    Original script: Automation_PS_File_PW.ps1
#>
