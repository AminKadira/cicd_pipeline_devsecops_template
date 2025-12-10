#!/bin/bash

# Configuration loader utility
CONFIG_DIR="${CONFIG_DIR:-./config}"

load_config() {
    local config_file="${1:-pipeline-config.json}"
    local config_path="$CONFIG_DIR/$config_file"
    
    if [ -f "$config_path" ]; then
        echo "Loading configuration from: $config_path"
        # Export common configurations as environment variables
        export PROJECT_NAME=$(jq -r '.project.name // "unknown"' "$config_path" 2>/dev/null || echo "unknown")
        export PROJECT_VERSION=$(jq -r '.project.version // "1.0.0"' "$config_path" 2>/dev/null || echo "1.0.0")
    else
        echo "Configuration file not found: $config_path"
        echo "Using default values"
        export PROJECT_NAME="unknown"
        export PROJECT_VERSION="1.0.0"
    fi
}

# Auto-load main config
load_config "pipeline-config.json"