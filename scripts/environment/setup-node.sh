#!/bin/bash
set -euo pipefail

echo "Setting up Node.js environment for secure build..."

# Validate Node.js installation
if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js not found"
    exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm not found"
    exit 1
fi

echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"

# Install dependencies
if [ -f package-lock.json ]; then
    npm ci --prefer-offline --no-audit
else
    npm install --prefer-offline --no-audit
fi

echo "Node.js environment setup completed"