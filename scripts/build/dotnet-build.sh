#!/bin/bash
set -euo pipefail

PROJECT_DIR="${1:-./app}"
CONFIG_FILE="${2:-./config/pipeline.json}"

# Configuration build
CONFIGURATION=$(jq -r '.build.dotnet.configuration' "$CONFIG_FILE")
VERBOSITY=$(jq -r '.build.dotnet.verbosity' "$CONFIG_FILE")
TREAT_WARNINGS_AS_ERRORS=$(jq -r '.build.dotnet.treatWarningsAsErrors' "$CONFIG_FILE")

echo "SECURITY: Starting secure .NET build..."
cd "$PROJECT_DIR"

# Validation environnement
dotnet --version || {
    echo "ERROR: .NET not found"
    exit 1
}

# NuGet security audit
echo "SECURITY: Running NuGet audit..."
dotnet list package --vulnerable --include-transitive || {
    echo "ERROR: Vulnerable packages detected"
    exit 1
}

# Build sécurisé
echo "SECURITY: Building with security flags..."
dotnet build \
    --configuration "$CONFIGURATION" \
    --verbosity "$VERBOSITY" \
    --property:TreatWarningsAsErrors="$TREAT_WARNINGS_AS_ERRORS" \
    --property:RunAnalyzersDuringBuild=true \
    --property:EnableNETAnalyzers=true \
    --no-restore

echo "SUCCESS: Secure build completed"