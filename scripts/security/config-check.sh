#!/bin/bash
set -euo pipefail

echo "=== SECURITY CONFIGURATION REVIEW ==="
echo "Purpose: Validate security configurations and best practices"
echo "OWASP Component: Security Configuration"
echo "Tools: Configuration file analysis, security headers check"
echo "Compliance: OWASP Top 10 - A05:2021 Security Misconfiguration"

PROJECT_DIR="${1:-./}"

cd "$PROJECT_DIR"

CONFIG_ISSUES=0

echo "Checking security configurations..."

# Check package.json for security configurations
if [ -f "package.json" ]; then
    echo "Analyzing package.json security settings..."
    
    if ! grep -q "helmet" package.json; then
        echo "INFO: Consider adding helmet for security headers"
    fi
    
    if ! grep -q "express-rate-limit" package.json; then
        echo "INFO: Consider adding rate limiting"
    fi
fi

# Check for HTTPS configuration
if grep -r "http://" src/ 2>/dev/null | grep -v localhost; then
    echo "WARNING: Non-localhost HTTP URLs found - consider HTTPS"
    CONFIG_ISSUES=$((CONFIG_ISSUES + 1))
fi

# Check for CORS configuration
if grep -r "cors" src/ 2>/dev/null; then
    echo "INFO: CORS configuration found - verify it's restrictive"
fi

# Generate report
mkdir -p reports/security
cat > reports/security/config-report.html << EOF
<!DOCTYPE html>
<html>
<head><title>Configuration Security Report</title></head>
<body>
<h1>Security Configuration Review</h1>
<p>Configuration Issues: $CONFIG_ISSUES</p>
<p>See console for recommendations.</p>
</body>
</html>
EOF

echo "Configuration security check completed - Issues: $CONFIG_ISSUES"