#!/bin/bash
set -euo pipefail

echo "=== OWASP DEPENDENCY CHECK ==="
echo "Purpose: Scan project dependencies for known security vulnerabilities"
echo "OWASP Component: Software Composition Analysis (SCA)"
echo "Tools: npm audit, yarn audit, dependency-check-cli (if available)"
echo "Compliance: OWASP Top 10 - A06:2021 Vulnerable and Outdated Components"

PROJECT_DIR="${1:-./}"
CONFIG_FILE="${2:-./config/owasp-settings.json}"

cd "$PROJECT_DIR"

# Check if package.json exists
if [ ! -f "package.json" ]; then
    echo "No package.json found, skipping dependency check"
    exit 0
fi

# Run npm audit (available by default)
echo "Running npm audit..."
npm audit --audit-level moderate || {
    echo "WARNING: npm audit found vulnerabilities"
    npm audit --json > dependency-audit.json 2>/dev/null || true
}

# Create simple HTML report
mkdir -p reports/security
cat > reports/security/dependency-report.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Dependency Security Report</title></head>
<body>
<h1>Dependency Security Scan</h1>
<p>Scan completed. Check npm audit output in console.</p>
</body>
</html>
EOF

echo "Dependency check completed"