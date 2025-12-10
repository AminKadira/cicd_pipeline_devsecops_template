#!/bin/bash
set -euo pipefail

echo "Performing cleanup operations..."

# Clean temporary files
find . -name "*.tmp" -type f -delete 2>/dev/null || true
find . -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true

echo "Cleanup completed"