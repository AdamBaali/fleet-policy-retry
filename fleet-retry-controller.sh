#!/usr/bin/env bash
# fleet-retry-controller.sh
# Purpose: Retry Fleet policy automations on hosts that are failing policies
# 
# Environment Variables:
#   FLEET_URL   - Fleet server URL (e.g., https://fleet.example.com)
#   FLEET_TOKEN - Fleet API token
# 
# Usage:
#   export FLEET_URL="https://your-fleet-instance.com"
#   export FLEET_TOKEN="your-api-token"
#   ./fleet-retry-controller.sh --dry-run   # Preview actions
#   ./fleet-retry-controller.sh             # Execute retries

set -euo pipefail

# Script configuration
SCRIPT_VERSION="1.0.1"

# Environment validation with clear errors (similar to Fleet's error patterns)
if [[ -z "${FLEET_URL:-}" ]]; then
  echo "Error: FLEET_URL environment variable is required" >&2
  exit 1
fi

if [[ -z "${FLEET_TOKEN:-}" ]]; then
  echo "Error: FLEET_TOKEN environment variable is required" >&2
  exit 1
fi

# Configuration
API_SLEEP="${API_SLEEP:-0.3}"
MAX_RETRIES="${MAX_RETRIES:-3}"
CACHE_FILE="${CACHE_FILE:-$HOME/.fleet_retry_cache.db}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
DRY_RUN=false
TEAMS_FILTER=""
EXCLUDE_POLICIES=""
LOG_FILE=""

# Backoff schedule (seconds): 30min -> 2h -> 6h -> 24h
BACKOFF_SCHEDULE=(1800 7200 21600 86400)

# Statistics
declare -A STATS=(
    [hosts_processed]=0
    [scripts_triggered]=0
    [software_triggered]=0
    [skipped_backoff]=0
    [skipped_max_retries]=0
    [api_errors]=0
    [policies_processed]=0
    [teams_processed]=0
)

# Logging - similar to Fleet's logging patterns
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Filter by log level
    case "$LOG_LEVEL" in
        DEBUG) [[ "$level" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]] || return ;;
        INFO)  [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]] || return ;;
        WARN)  [[ "$level" =~ ^(WARN|ERROR)$ ]] || return ;;
        ERROR) [[ "$level" = "ERROR" ]] || return ;;
        *) LOG_LEVEL="INFO"; [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]] || return ;;
    esac
    
    echo "[$timestamp] $level: $message" >&2
    
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] $level: $message" >> "$LOG_FILE"
    fi
}

# Parse arguments - Fleet CLI tools use similar patterns
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --teams=*)
                TEAMS_FILTER="${1#*=}"
                shift
                ;;
            --exclude-policies=*)
                EXCLUDE_POLICIES="${1#*=}"
                shift
                ;;
            --max-retries=*)
                MAX_RETRIES="${1#*=}"
                if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
                    log "ERROR" "Invalid max-retries value: $MAX_RETRIES"
                    exit 1
                fi
                shift
                ;;
            --log-file=*)
                LOG_FILE="${1#*=}"
                # Create parent directory if needed
                mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
                touch "$LOG_FILE" 2>/dev/null || {
                    log "ERROR" "Cannot write to log file: $LOG_FILE"
                    exit 1
                }
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            --version)
                echo "fleet-retry-controller v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

show_usage() {
    cat << EOF
fleet-retry-controller v$SCRIPT_VERSION

Usage: fleet-retry-controller.sh [OPTIONS]

OPTIONS:
    --dry-run                Preview actions without executing
    --verbose, -v            Enable verbose logging
    --teams=LIST             Comma-separated team names to process
    --exclude-policies=LIST  Comma-separated policy names to exclude
    --max-retries=N          Maximum retry attempts (default: $MAX_RETRIES)
    --log-file=FILE          Log to file in addition to stderr
    --help, -h               Show this help message
    --version                Show version information

ENVIRONMENT VARIABLES:
    FLEET_URL     Fleet server URL (required)
    FLEET_TOKEN   Fleet API token (required)
    API_SLEEP     Sleep between API calls (default: $API_SLEEP)
    MAX_RETRIES   Maximum retry attempts (default: $MAX_RETRIES)
    LOG_LEVEL     Logging level: DEBUG/INFO/WARN/ERROR (default: $LOG_LEVEL)

EXAMPLES:
    # Preview what would be retried
    ./fleet-retry-controller.sh --dry-run
    
    # Process only specific teams
    ./fleet-retry-controller.sh --teams="Production,Staging"
EOF
}

# API functions - simplified error handling like Fleet's Go code
api_call() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local response_file
    
    response_file=$(mktemp)
    
    local curl_cmd=(
        curl -sfS
        --retry 3
        --retry-delay 1
        -H "Authorization: Bearer $FLEET_TOKEN"
        -H "Content-Type: application/json"
        -w "%{http_code}"
        -o "$response_file"
    )
    
    if [[ "$method" = "POST" && -n "$data" ]]; then
        curl_cmd+=(-X POST -d "$data")
    fi
    
    # Clean URL
    local url="${FLEET_URL%/}$path"
    
    local status_code
    if status_code=$(${curl_cmd[@]} "$url"); then
        if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
            cat "$response_file"
            rm -f "$response_file"
            sleep "$API_SLEEP"
            return 0
        else
            log "ERROR" "API $method $path failed with status $status_code"
            rm -f "$response_file"
            ((STATS[api_errors]++))
            return 1
        fi
    else
        log "ERROR" "API request to $path failed"
        rm -f "$response_file"
        ((STATS[api_errors]++))
        return 1
    fi
}

api_get() { api_call "GET" "$@"; }

api_post() {
    if [[ "$DRY_RUN" = true ]]; then
        log "INFO" "[DRY-RUN] Would POST to $1 with data: $2"
        return 0
    fi
    api_call "POST" "$@"
}

# Cache functions
cache_init() {
    # Create parent directory if needed
    mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
    touch "$CACHE_FILE" || {
        log "ERROR" "Cannot write to cache file: $CACHE_FILE"
        exit 1
    }
    
    # Clean old entries (>7 days)
    local cutoff
    cutoff=$(($(date +%s) - 604800))
    local tmp_file
    tmp_file=$(mktemp)
    
    awk -F'|' -v cutoff="$cutoff" '$2 >= cutoff' "$CACHE_FILE" > "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$CACHE_FILE"
}

cache_get() {
    local key="$1"
    local escaped_key
    
    escaped_key=$(echo "$key" | sed 's/[\/&]/\\&/g')
    grep -E "^${escaped_key}\\|" "$CACHE_FILE" 2>/dev/null || true
}

cache_set() {
    local key="$1"
    local timestamp="$2"
    local retry_count="$3"
    local tmp_file
    local escaped_key
    
    tmp_file=$(mktemp)
    escaped_key=$(echo "$key" | sed 's/[\/&]/\\&/g')
    
    grep -vE "^${escaped_key}\\|" "$CACHE_FILE" > "$tmp_file" 2>/dev/null || true
    printf "%s|%s|%s\n" "$key" "$timestamp" "$retry_count" >> "$tmp_file"
    mv "$tmp_file" "$CACHE_FILE"
}

# Check if retry needed based on backoff
should_retry() {
    local cache_key="$1"
    local cache_entry
    
    cache_entry=$(cache_get "$cache_key")
    
    if [[ -z "$cache_entry" ]]; then
        log "DEBUG" "First retry for $cache_key"
        return 0  # First try
    fi
    
    # Parse cache entry
    local last_timestamp retry_count
    IFS='|' read -r _ last_timestamp retry_count <<< "$cache_entry"
    
    # Check max retries
    if [[ $retry_count -ge $MAX_RETRIES ]]; then
        log "DEBUG" "Max retries reached for $cache_key"
        ((STATS[skipped_max_retries]++))
        return 1
    fi
    
    # Get backoff time
    local index=$((retry_count - 1))
    local backoff_seconds
    
    if [[ $index -lt 0 ]]; then
        backoff_seconds=0
    elif [[ $index -ge ${#BACKOFF_SCHEDULE[@]} ]]; then
        backoff_seconds="${BACKOFF_SCHEDULE[-1]}"
    else
        backoff_seconds="${BACKOFF_SCHEDULE[$index]}"
    fi
    
    # Check if backoff period has passed
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - last_timestamp))
    
    if [[ $elapsed -lt $backoff_seconds ]]; then
        log "DEBUG" "In backoff period for $cache_key ($((backoff_seconds - elapsed))s remaining)"
        ((STATS[skipped_backoff]++))
        return 1
    fi
    
    log "DEBUG" "Ready to retry $cache_key (attempt $((retry_count + 1)))"
    return 0
}

# Fleet interaction functions
run_script_on_host() {
    local host_id="$1"
    local script_id="$2"
    local policy_name="$3"
    
    log "INFO" "Running script $script_id on host $host_id for policy '$policy_name'"
    
    local payload
    payload=$(jq -n \
        --argjson host_id "$host_id" \
        --argjson script_id "$script_id" \
        '{host_id: $host_id, script_id: $script_id}')
    
    if api_post "/api/v1/fleet/scripts/run" "$payload" >/dev/null; then
        log "INFO" "Script triggered for host $host_id"
        ((STATS[scripts_triggered]++))
        return 0
    else
        log "ERROR" "Failed to trigger script for host $host_id"
        return 1
    fi
}

install_software_on_host() {
    local host_id="$1"
    local software_id="$2"
    local policy_name="$3"
    
    log "INFO" "Installing software $software_id on host $host_id for policy '$policy_name'"
    
    if api_post "/api/v1/fleet/hosts/$host_id/software/$software_id/install" "{}" >/dev/null; then
        log "INFO" "Software install triggered for host $host_id"
        ((STATS[software_triggered]++))
        return 0
    else
        log "ERROR" "Failed to trigger software install for host $host_id"
        return 1
    fi
}

# Filter functions
should_process_team() {
    local team_name="$1"
    
    if [[ -z "$TEAMS_FILTER" ]]; then
        return 0  # No filter, process all
    fi
    
    local IFS=','
    for filter_team in $TEAMS_FILTER; do
        filter_team=$(echo "$filter_team" | xargs)
        if [[ "$team_name" = "$filter_team" ]]; then
            return 0
        fi
    done
    
    return 1  # Not in filter
}

should_process_policy() {
    local policy_name="$1"
    
    if [[ -z "$EXCLUDE_POLICIES" ]]; then
        return 0  # No exclusions
    fi
    
    local IFS=','
    for exclude_policy in $EXCLUDE_POLICIES; do
        exclude_policy=$(echo "$exclude_policy" | xargs)
        if [[ "$policy_name" = "$exclude_policy" ]]; then
            return 1  # Excluded
        fi
    done
    
    return 0  # Not excluded
}

# Process functions
process_failing_hosts() {
    local team_id="$1"
    local team_name="$2"
    local policy_id="$3"
    local policy_name="$4"
    local script_id="$5"
    local software_id="$6"
    
    # Skip if no automation
    if [[ -z "$script_id" && -z "$software_id" ]]; then
        log "DEBUG" "Policy '$policy_name' has no automation configured"
        return 0
    fi
    
    log "INFO" "Processing failing hosts for policy '$policy_name'"
    
    # Paginate through hosts
    local page=0
    local per_page=100
    local failing_hosts=0
    
    while true; do
        local hosts_response
        local query="page=$page&per_page=$per_page"
        
        if [[ "$team_id" != "global" ]]; then
            query="$query&team_id=$team_id"
        fi
        
        if ! hosts_response=$(api_get "/api/v1/fleet/hosts?$query"); then
            log "ERROR" "Failed to retrieve hosts for team '$team_name'"
            break
        fi
        
        # Check if we got any hosts
        local hosts_count
        hosts_count=$(echo "$hosts_response" | jq '.hosts | length')
        
        if [[ "$hosts_count" -eq 0 ]]; then
            break  # No more hosts
        fi
        
        # Process hosts
        echo "$hosts_response" | jq -c '.hosts[]' | while read -r host; do
            local host_id
            host_id=$(echo "$host" | jq -r '.id')
            
            # Check if host is failing the policy
            local policy_status
            policy_status=$(echo "$host" | jq -r --argjson pid "$policy_id" '.policies[] | select(.id == $pid) | .response // "unknown"')
            
            if [[ "$policy_status" != "fail" ]]; then
                continue  # Not failing
            fi
            
            ((STATS[hosts_processed]++))
            failing_hosts=$((failing_hosts + 1))
            
            # Check if we should retry
            local cache_key="${host_id}:${policy_id}:${team_id}"
            
            if ! should_retry "$cache_key"; then
                continue  # Skip (backoff or max retries)
            fi
            
            # Get current retry count
            local cache_entry retry_count=0
            cache_entry=$(cache_get "$cache_key")
            if [[ -n "$cache_entry" ]]; then
                IFS='|' read -r _ _ retry_count <<< "$cache_entry"
            fi
            
            # Attempt remediation
            local success=false
            if [[ -n "$script_id" && "$script_id" != "null" ]]; then
                if run_script_on_host "$host_id" "$script_id" "$policy_name"; then
                    success=true
                fi
            elif [[ -n "$software_id" && "$software_id" != "null" ]]; then
                if install_software_on_host "$host_id" "$software_id" "$policy_name"; then
                    success=true
                fi
            fi
            
            # Update retry count
            cache_set "$cache_key" "$(date +%s)" "$((retry_count + 1))"
        done
        
        page=$((page + 1))
    done
    
    if [[ $failing_hosts -gt 0 ]]; then
        log "INFO" "Processed $failing_hosts failing hosts for policy '$policy_name'"
    fi
}

process_team_policies() {
    local team_id="$1"
    local team_name="$2"
    
    if ! should_process_team "$team_name"; then
        log "DEBUG" "Skipping team '$team_name' (not in filter)"
        return 0
    fi
    
    log "INFO" "Processing team: $team_name"
    ((STATS[teams_processed]++))
    
    # Get policies for team
    local policies_endpoint
    if [[ "$team_id" = "global" ]]; then
        policies_endpoint="/api/v1/fleet/policies"
    else
        policies_endpoint="/api/v1/fleet/teams/$team_id/policies"
    fi
    
    local policies_response
    if ! policies_response=$(api_get "$policies_endpoint"); then
        log "ERROR" "Failed to retrieve policies for team '$team_name'"
        return 1
    fi
    
    local policies_count
    policies_count=$(echo "$policies_response" | jq '.policies | length')
    log "INFO" "Found $policies_count policies in team '$team_name'"
    
    # Process each policy
    echo "$policies_response" | jq -c '.policies[]' | while read -r policy; do
        local policy_id policy_name script_id software_id
        policy_id=$(echo "$policy" | jq -r '.id')
        policy_name=$(echo "$policy" | jq -r '.name')
        
        if ! should_process_policy "$policy_name"; then
            log "DEBUG" "Skipping excluded policy '$policy_name'"
            continue
        fi
        
        ((STATS[policies_processed]++))
        
        # Extract automation configuration
        script_id=$(echo "$policy" | jq -r '.run_script.id // .automation.run_script.id // empty')
        software_id=$(echo "$policy" | jq -r '.install_software.software_title_id // .automation.install_software.software_title_id // empty')
        
        process_failing_hosts "$team_id" "$team_name" "$policy_id" "$policy_name" "$script_id" "$software_id"
    done
}

# Show execution statistics
show_stats() {
    log "INFO" "=== Execution Statistics ==="
    log "INFO" "Teams processed: ${STATS[teams_processed]}"
    log "INFO" "Policies processed: ${STATS[policies_processed]}"
    log "INFO" "Hosts processed: ${STATS[hosts_processed]}"
    log "INFO" "Scripts triggered: ${STATS[scripts_triggered]}"
    log "INFO" "Software installs triggered: ${STATS[software_triggered]}"
    log "INFO" "Skipped (backoff): ${STATS[skipped_backoff]}"
    log "INFO" "Skipped (max retries): ${STATS[skipped_max_retries]}"
    log "INFO" "API errors: ${STATS[api_errors]}"
}

# Graceful shutdown
trap 'log "INFO" "Shutting down..."; show_stats; exit 0' SIGINT SIGTERM

# Main function
main() {
    log "INFO" "Starting fleet-retry-controller v$SCRIPT_VERSION"
    
    if [[ "$DRY_RUN" = true ]]; then
        log "INFO" "Running in dry-run mode (no actions will be taken)"
    fi
    
    cache_init
    
    # Process global policies first
    log "INFO" "Processing global policies"
    process_team_policies "global" "Global"
    
    # Get and process teams
    local teams_response
    if ! teams_response=$(api_get "/api/v1/fleet/teams"); then
        log "ERROR" "Failed to retrieve teams"
        exit 1
    fi
    
    local teams_count
    teams_count=$(echo "$teams_response" | jq '.teams | length')
    log "INFO" "Found $teams_count teams"
    
    # Process each team
    echo "$teams_response" | jq -c '.teams[]' | while read -r team; do
        local team_id team_name
        team_id=$(echo "$team" | jq -r '.id')
        team_name=$(echo "$team" | jq -r '.name')
        
        process_team_policies "$team_id" "$team_name"
    done
    
    show_stats
    log "INFO" "Fleet policy retry controller completed successfully"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    main
fi
