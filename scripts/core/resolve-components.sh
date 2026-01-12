#!/bin/bash
# scripts/core/resolve-components.sh
# Extrait et prépare les composants depuis la config V2
# Exit codes: 0=OK, 1=Erreur

set -euo pipefail

SCRIPT_NAME="resolve-components"

usage() {
    echo "Usage: $0 -c CONFIG_PATH -e ENVIRONMENT [-w WORKSPACE] [-o OUTPUT_FILE] [-s SERVER]"
    exit 1
}

CONFIG_PATH=""
ENVIRONMENT=""
WORKSPACE="${WORKSPACE:-$(pwd)}"
OUTPUT_FILE=""
TARGET_SERVER=""

while getopts "c:e:w:o:s:" opt; do
    case $opt in
        c) CONFIG_PATH="$OPTARG" ;;
        e) ENVIRONMENT="$OPTARG" ;;
        w) WORKSPACE="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        s) TARGET_SERVER="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -z "$CONFIG_PATH" || -z "$ENVIRONMENT" ]] && usage

log() {
    echo "[$SCRIPT_NAME][$1] $2" >&2
}

env_var() {
    echo "$1=$2"
}

if ! command -v jq &> /dev/null; then
    log "ERROR" "jq is required"
    exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
    log "ERROR" "Config not found: $CONFIG_PATH"
    exit 1
fi

# Normaliser environnement
ENV_DISPLAY=$(echo "$ENVIRONMENT" | sed 's/./\U&/')  # Première lettre maj

log "INFO" "Resolving components..."
log "INFO" "  Config: $CONFIG_PATH"
log "INFO" "  Environment: $ENV_DISPLAY"
log "INFO" "  Workspace: $WORKSPACE"

config=$(cat "$CONFIG_PATH")

# Vérifier V2
if ! echo "$config" | jq -e '.components' > /dev/null 2>&1; then
    log "ERROR" "Config does not have 'components' section (V2 required)"
    exit 1
fi

# Fonction de substitution de variables
substitute_vars() {
    local template="$1"
    local component_name="$2"
    
    echo "$template" | sed \
        -e "s|\${WORKSPACE}|$WORKSPACE|g" \
        -e "s|\${environment}|$ENV_DISPLAY|g" \
        -e "s|\${component.name}|$component_name|g" \
        -e "s|\${server}|$TARGET_SERVER|g"
}

# Extraire composants
project_name=$(echo "$config" | jq -r '.project.name')
categories=("apis" "webApps" "consoleServices" "batches" "angular" "dbScripts")

declare -A counts
declare -A names_lists
total=0

for category in "${categories[@]}"; do
    # Filtrer enabled != false
    items=$(echo "$config" | jq -c ".components.$category // [] | map(select(.enabled != false))")
    count=$(echo "$items" | jq 'length')
    names=$(echo "$items" | jq -r '.[].name' | tr '\n' ',' | sed 's/,$//')
    
    counts[$category]=$count
    names_lists[$category]=$names
    total=$((total + count))
    
    log "INFO" "  $category: $count component(s)"
done

# Générer JSON de sortie si demandé
if [[ -n "$OUTPUT_FILE" ]]; then
    components_json="[]"
    
    for category in "${categories[@]}"; do
        items=$(echo "$config" | jq -c ".components.$category // [] | map(select(.enabled != false))")
        
        while IFS= read -r component; do
            [[ -z "$component" || "$component" == "null" ]] && continue
            
            name=$(echo "$component" | jq -r '.name')
            script=$(echo "$component" | jq -r '.script // empty')
            deploy_script=$(echo "$component" | jq -r '.deployScript // empty')
            
            # Substituer variables
            script=$(substitute_vars "$script" "$name")
            deploy_script=$(substitute_vars "$deploy_script" "$name")
            
            # Substituer dans params
            params=$(echo "$component" | jq -c '.params // {}')
            params=$(substitute_vars "$params" "$name")
            
            deploy_params=$(echo "$component" | jq -c '.deployParams // {}')
            deploy_params=$(substitute_vars "$deploy_params" "$name")
            
            resolved=$(jq -n \
                --arg name "$name" \
                --arg category "$category" \
                --arg build_script "$script" \
                --arg deploy_script "$deploy_script" \
                --argjson build_params "$params" \
                --argjson deploy_params "$deploy_params" \
                '{
                    name: $name,
                    category: $category,
                    enabled: true,
                    build: { script: $build_script, params: $build_params },
                    deploy: { script: $deploy_script, params: $deploy_params }
                }')
            
            components_json=$(echo "$components_json" | jq --argjson c "$resolved" '. + [$c]')
            
        done < <(echo "$items" | jq -c '.[]')
    done
    
    # Écrire fichier
    jq -n \
        --arg project "$project_name" \
        --arg environment "$ENV_DISPLAY" \
        --arg workspace "$WORKSPACE" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson components "$components_json" \
        --argjson counts "$(jq -n \
            --arg total "$total" \
            --arg apis "${counts[apis]}" \
            --arg webApps "${counts[webApps]}" \
            --arg consoleServices "${counts[consoleServices]}" \
            --arg batches "${counts[batches]}" \
            --arg angular "${counts[angular]}" \
            --arg dbScripts "${counts[dbScripts]}" \
            '{total:($total|tonumber), apis:($apis|tonumber), webApps:($webApps|tonumber), consoleServices:($consoleServices|tonumber), batches:($batches|tonumber), angular:($angular|tonumber), dbScripts:($dbScripts|tonumber)}')" \
        '{
            project: $project,
            environment: $environment,
            workspace: $workspace,
            timestamp: $timestamp,
            counts: $counts,
            components: $components
        }' > "$OUTPUT_FILE"
    
    log "INFO" "Components written to: $OUTPUT_FILE"
fi

# Exporter variables
env_var "COMPONENTS_TOTAL" "$total"
env_var "COMPONENTS_APIS" "${counts[apis]}"
env_var "COMPONENTS_WEBAPPS" "${counts[webApps]}"
env_var "COMPONENTS_CONSOLE" "${counts[consoleServices]}"
env_var "COMPONENTS_BATCHES" "${counts[batches]}"
env_var "COMPONENTS_ANGULAR" "${counts[angular]}"
env_var "COMPONENTS_DBSCRIPTS" "${counts[dbScripts]}"

env_var "COMPONENTS_APIS_LIST" "${names_lists[apis]}"
env_var "COMPONENTS_WEBAPPS_LIST" "${names_lists[webApps]}"
env_var "COMPONENTS_CONSOLE_LIST" "${names_lists[consoleServices]}"
env_var "COMPONENTS_BATCHES_LIST" "${names_lists[batches]}"
env_var "COMPONENTS_ANGULAR_LIST" "${names_lists[angular]}"

log "INFO" "Component resolution completed: $total component(s)"
exit 0