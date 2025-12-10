#!/bin/bash
set -euo pipefail

echo "=== ENVIRONMENT VALIDATION ==="
echo "Validating Jenkins environment and required tools"
echo "Purpose: Ensure all necessary tools are available for secure pipeline execution"
echo "Tools checked: Node.js, npm, Git, basic security utilities"

# Load configuration
source "$(dirname "$0")/../utils/load-config.sh"

# Validate Node.js
if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js not found"
    exit 1
fi

# Validate npm
if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm not found"
    exit 1
fi

# Check available security tools
echo "=== SECURITY TOOLS AVAILABILITY ==="
command -v git >/dev/null && echo "✓ Git available" || echo "✗ Git missing"
command -v grep >/dev/null && echo "✓ grep available" || echo "✗ grep missing"
command -v find >/dev/null && echo "✓ find available" || echo "✗ find missing"

echo "Environment validation completed"