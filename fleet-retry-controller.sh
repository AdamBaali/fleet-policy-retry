#!/usr/bin/env bash
# fleet-retry-final.sh
# Purpose: Retry Fleet policy automations on hosts that are failing policies
# Updated with correct Fleet API endpoints for both script and software automation
# 
# Usage:
#   ./fleet-retry-final.sh --dry-run   # Preview actions
#   ./fleet-retry-final.sh             # Execute retries

set -euo pipefail

# Script configuration
SCRIPT_VERSION="1.2.0"

# ========================================
# CREDENTIALS CONFIGURATION
# ========================================
# Fleet server URL (e.g., https://fleet.example.com)
FLEET_URL="https://your-fleet-instance.com"

# Fleet API token
FLEET_TOKEN="your-api-token-here"
# ========================================

# Enhanced validation
if [[ "$FLEET_URL" == "https://your-fleet-instance.com" ]]; then
  echo "Error: Please edit this script and set your actual Fleet URL" >&2
  exit 1
fi

if [[ ! "$FLEET_URL" =~ ^https?:// ]]; then
  echo "Error: Fleet URL must start with http:// or https://" >&2
  exit 1
fi

if [[ "$FLEET_TOKEN" == "your-api-token-here" ]]; then
  echo "Error: Please edit this script and set your actual Fleet API token" >&2
  exit 1
fi

# Configuration
API_SLEEP="0.3"
MAX_RETRIES="3"
CACHE_FILE="$HOME/.fleet_retry_cache.db"
LOG_LEVEL="INFO"
DRY_RUN=false
TEAMS_FILTER=""
EXCLUDE_POLICIES=""
LOG_FILE=""

# Backoff schedule (seconds): 30min -> 2h -> 6h -> 24h
BACKOFF_SCHEDULE=(1800 7200 21600 86400)

# Statistics tracking
hosts_processed=0
scripts_triggered=0
software_triggered=0
api_errors=0
policies_processed=0
teams_processed=0
skipped_backoff=0
skipped_max_retries=0

# Logging
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

# Parse arguments
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
                echo "fleet-retry-final v$SCRIPT_VERSION"
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
fleet-retry-final v$SCRIPT_VERSION

Usage: fleet-retry-final.sh [OPTIONS]

OPTIONS:
    --dry-run                Preview actions without executing
    --verbose, -v            Enable verbose logging
    --teams=LIST             Comma-separated team names to process
    --exclude-policies=LIST  Comma-separated policy names to exclude
    --max-retries=N          Maximum retry attempts (default: $MAX_RETRIES)
    --log-file=FILE          Log to file in addition to stderr
    --help, -h               Show this help message
    --version                Show version information

CONFIGURATION:
    Edit this script to set:
    - FLEET_URL     Fleet server URL
    - FLEET_TOKEN   Fleet API token

EXAMPLES:
    # Preview what would be retried
    ./fleet-retry-final.sh --dry-run
    
    # Process only specific teams
    ./fleet-retry-final.sh --teams="Production,Staging"
EOF
}

# API functions
api_call() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local response_file
    
    response_file=$(mktemp)
    
    # Clean URL
    local url="${FLEET_URL%/}$path"
    
    # Build curl command as a single command to avoid parsing issues
    local curl_cmd=(curl -sfS --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60)
    curl_cmd+=(-H "Authorization: Bearer $FLEET_TOKEN")
    curl_cmd+=(-H "Content-Type: application/json")
    curl_cmd+=(-w "%{http_code}")
    curl_cmd+=(-o "$response_file")
    
    if [[ "$method" = "POST" && -n "$data" ]]; then
        curl_cmd+=(-X POST -d "$data")
    fi
    
    curl_cmd+=("$url")
    
    log "DEBUG" "Executing API request to $path"
    
    # Execute curl command
    local status_code
    if status_code=$("${curl_cmd[@]}" 2>/dev/null); then
        if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
            cat "$response_file"
            rm -f "$response_file"
            sleep "$API_SLEEP"
            return 0
        else
            log "ERROR" "API $method $path failed with status $status_code"
            log "DEBUG" "Response content: $(cat "$response_file" 2>/dev/null || echo 'empty')"
            rm -f "$response_file"
            api_errors=$((api_errors + 1))
            return 1
        fi
    else
        local exit_code=$?
        log "ERROR" "API request to $path failed (curl exit code: $exit_code)"
        rm -f "$response_file"
        api_errors=$((api_errors + 1))
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
        skipped_max_retries=$((skipped_max_retries + 1))
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
        skipped_backoff=$((skipped_backoff + 1))
        return 1
    fi
    
    log "DEBUG" "Ready to retry $cache_key (attempt $((retry_count + 1)))"
    return 0
}

# CORRECTED: Fleet script execution function using the proper API endpoint
run_script_on_host() {
    local host_id="$1"
    local script_id="$2"
    local policy_name="$3"
    
    log "INFO" "Running script $script_id on host $host_id for policy '$policy_name'"
    
    # Check if script_id is numeric
    if ! [[ "$script_id" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Invalid script ID: $script_id"
        return 1
    fi
    
    # Per Fleet API documentation, we need to use this endpoint
    local endpoint="/api/v1/fleet/scripts/run"
    
    # Build payload with correct format from the documentation
    local payload
    payload=$(jq -n \
        --arg host_id "$host_id" \
        --arg script_id "$script_id" \
        '{host_id: ($host_id | tonumber), script_id: ($script_id | tonumber)}')
    
    log "DEBUG" "Using script execution endpoint: $endpoint with payload: $payload"
    
    if api_post "$endpoint" "$payload" >/dev/null; then
        log "INFO" "Script triggered for host $host_id"
        scripts_triggered=$((scripts_triggered + 1))
        return 0
    else
        log "ERROR" "Failed to trigger script for host $host_id"
        return 1
    fi
}

# CORRECTED: Fleet software installation function using the proper API endpoint
install_software_on_host() {
    local host_id="$1"
    local software_id="$2"
    local policy_name="$3"
    
    log "INFO" "Installing software $software_id on host $host_id for policy '$policy_name'"
    
    # Check if software_id is numeric
    if ! [[ "$software_id" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Invalid software ID: $software_id"
        return 1
    fi
    
    # Per Fleet API documentation, this is the correct endpoint for software installation
    local endpoint="/api/v1/fleet/hosts/$host_id/software/$software_id/install"
    local payload="{}"
    
    log "DEBUG" "Using software installation endpoint: $endpoint"
    
    if api_post "$endpoint" "$payload" >/dev/null; then
        log "INFO" "Software install triggered for host $host_id"
        software_triggered=$((software_triggered + 1))
        return 0
    else
        log "ERROR" "Failed to trigger software install for host $host_id"
        return 1
    fi
}

# Get software details from Fleet
get_software_details() {
    local software_id="$1"
    
    log "DEBUG" "Fetching details for software ID $software_id"
    local software_response
    
    # Per Fleet API documentation, this endpoint provides software details
    if ! software_response=$(api_get "/api/v1/fleet/software/$software_id"); then
        log "WARN" "Failed to retrieve details for software ID $software_id"
        return 1
    fi
    
    echo "$software_response"
    return 0
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

# Extract automation from policy based on actual Fleet API structure
extract_policy_automation() {
    local policy="$1"
    local policy_name="$2"
    
    # Debug the policy structure
    log "DEBUG" "Checking automation for policy: $policy_name"
    
    # Extract run_script.id using various possible paths
    local script_id=""
    
    # Try to find script_id in all the possible locations in the Fleet API
    if echo "$policy" | jq -e '.automation.run_script.id' > /dev/null 2>&1; then
        script_id=$(echo "$policy" | jq -r '.automation.run_script.id')
        log "DEBUG" "Found script_id in .automation.run_script.id: $script_id"
    elif echo "$policy" | jq -e '.automation.script_id' > /dev/null 2>&1; then
        script_id=$(echo "$policy" | jq -r '.automation.script_id')
        log "DEBUG" "Found script_id in .automation.script_id: $script_id"
    elif echo "$policy" | jq -e '.run_script.id' > /dev/null 2>&1; then
        script_id=$(echo "$policy" | jq -r '.run_script.id')
        log "DEBUG" "Found script_id in .run_script.id: $script_id"
    elif echo "$policy" | jq -e '.automation.remediation.scripts[0].id' > /dev/null 2>&1; then
        script_id=$(echo "$policy" | jq -r '.automation.remediation.scripts[0].id')
        log "DEBUG" "Found script_id in .automation.remediation.scripts[0].id: $script_id"
    fi
    
    # Extract software_id using various possible paths
    local software_id=""
    
    # Try all possible paths where software_id might be found
    if echo "$policy" | jq -e '.automation.install_software.software_title_id' > /dev/null 2>&1; then
        software_id=$(echo "$policy" | jq -r '.automation.install_software.software_title_id')
        log "DEBUG" "Found software_id in .automation.install_software.software_title_id: $software_id"
    elif echo "$policy" | jq -e '.automation.software_id' > /dev/null 2>&1; then
        software_id=$(echo "$policy" | jq -r '.automation.software_id')
        log "DEBUG" "Found software_id in .automation.software_id: $software_id"
    elif echo "$policy" | jq -e '.install_software.software_title_id' > /dev/null 2>&1; then
        software_id=$(echo "$policy" | jq -r '.install_software.software_title_id')
        log "DEBUG" "Found software_id in .install_software.software_title_id: $software_id"
    elif echo "$policy" | jq -e '.automation.remediation.software[0].id' > /dev/null 2>&1; then
        software_id=$(echo "$policy" | jq -r '.automation.remediation.software[0].id')
        log "DEBUG" "Found software_id in .automation.remediation.software[0].id: $software_id"
    fi
    
    # Additional logging for debugging
    if [[ -n "$software_id" ]]; then
        log "INFO" "Policy '$policy_name' has software installation automation (ID: $software_id)"
    fi
    
    if [[ -n "$script_id" ]]; then
        log "INFO" "Policy '$policy_name' has script automation (ID: $script_id)"
    fi
    
    # Return both values
    echo "$script_id|$software_id"
}

# Get failing hosts using the proper Fleet API endpoint
get_failing_hosts_for_policy() {
    local team_id="$1"
    local policy_id="$2"
    
    # Build query string with proper parameters from Fleet API docs
    local query="policy_id=$policy_id&policy_response=failing"
    
    # Add team_id parameter for team-specific failing hosts
    if [[ -n "$team_id" ]]; then
        query="${query}&team_id=$team_id"
    fi
    
    # Add pagination parameters
    query="${query}&per_page=100"
    
    log "DEBUG" "Fetching failing hosts with query: $query"
    local endpoint="/api/v1/fleet/hosts?$query"
    local response
    
    if ! response=$(api_get "$endpoint"); then
        log "ERROR" "Failed to retrieve failing hosts for policy $policy_id"
        return 1
    fi
    
    echo "$response"
    return 0
}

# Process functions - UPDATED to check software installations
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
    
    # Get failing hosts for this policy
    local failing_hosts_response
    if ! failing_hosts_response=$(get_failing_hosts_for_policy "$team_id" "$policy_id"); then
        log "WARN" "Could not retrieve failing hosts for policy '$policy_name', skipping"
        return 0
    fi
    
    # Check if we have a valid hosts response
    if ! echo "$failing_hosts_response" | jq -e '.hosts' > /dev/null 2>&1; then
        log "ERROR" "Invalid or empty hosts response"
        return 1
    fi
    
    # Get the hosts array
    local hosts_json
    hosts_json=$(echo "$failing_hosts_response" | jq -c '.hosts[]' 2>/dev/null)
    
    # If no hosts are failing, hosts_json will be empty
    if [[ -z "$hosts_json" ]]; then
        log "INFO" "No failing hosts found for policy '$policy_name'"
        return 0
    fi
    
    # Count total failing hosts for this policy
    local failing_count
    failing_count=$(echo "$failing_hosts_response" | jq '.hosts | length')
    log "INFO" "Found $failing_count hosts failing policy '$policy_name'"
    
    local failing_hosts=0
    
    # Process each failing host
    echo "$hosts_json" | while read -r host; do
        # Skip if null/empty
        if [[ -z "$host" || "$host" == "null" ]]; then
            continue
        fi
        
        local host_id
        host_id=$(echo "$host" | jq -r '.id')
        
        hosts_processed=$((hosts_processed + 1))
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
        
        # Log host details
        local hostname
        hostname=$(echo "$host" | jq -r '.hostname // .computer_name // "unknown"')
        log "INFO" "Processing host: $hostname (ID: $host_id)"
        
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
    
    if [[ $failing_hosts -gt 0 ]]; then
        log "INFO" "Processed $failing_hosts failing hosts for policy '$policy_name'"
    else
        log "INFO" "No failing hosts found for policy '$policy_name'"
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
    teams_processed=$((teams_processed + 1))
    
    # Get policies for team - using the team-specific endpoint
    local policies_endpoint="/api/v1/fleet/teams/$team_id/policies"
    
    log "DEBUG" "Fetching policies from $policies_endpoint"
    local policies_response
    if ! policies_response=$(api_get "$policies_endpoint"); then
        log "ERROR" "Failed to retrieve policies for team '$team_name'"
        return 1
    fi
    
    # Check if we have a valid policies response
    if ! echo "$policies_response" | jq -e '.policies' > /dev/null 2>&1; then
        log "ERROR" "Invalid or empty policies response for team '$team_name'"
        return 1
    fi
    
    local policies_count
    policies_count=$(echo "$policies_response" | jq '.policies | length')
    log "INFO" "Found $policies_count policies in team '$team_name'"
    
    # Process each policy
    echo "$policies_response" | jq -c '.policies[]' | while read -r policy; do
        local policy_id policy_name
        policy_id=$(echo "$policy" | jq -r '.id')
        policy_name=$(echo "$policy" | jq -r '.name')
        
        if ! should_process_policy "$policy_name"; then
            log "DEBUG" "Skipping excluded policy '$policy_name'"
            continue
        fi
        
        # IMPROVED: Use the extract_policy_automation function to get automation details
        local automation_info script_id software_id
        automation_info=$(extract_policy_automation "$policy" "$policy_name")
        IFS='|' read -r script_id software_id <<< "$automation_info"
        
        # Only count as processed if we actually do something with it
        if [[ -n "$script_id" || -n "$software_id" ]]; then
            policies_processed=$((policies_processed + 1))
            process_failing_hosts "$team_id" "$team_name" "$policy_id" "$policy_name" "$script_id" "$software_id"
        else
            log "DEBUG" "Policy '$policy_name' has no automation configured"
        fi
    done
    
    return 0
}

# Show execution statistics
show_stats() {
    log "INFO" "=== Execution Statistics ==="
    log "INFO" "Teams processed: $teams_processed"
    log "INFO" "Policies processed: $policies_processed"
    log "INFO" "Hosts processed: $hosts_processed"
    log "INFO" "Scripts triggered: $scripts_triggered"
    log "INFO" "Software installs triggered: $software_triggered"
    log "INFO" "Skipped (backoff): $skipped_backoff"
    log "INFO" "Skipped (max retries): $skipped_max_retries"
    log "INFO" "API errors: $api_errors"
}

# Graceful shutdown
trap 'log "INFO" "Shutting down..."; show_stats; exit 0' SIGINT SIGTERM

# Main function
main() {
    log "INFO" "Starting fleet-retry-final v$SCRIPT_VERSION"
    
    if [[ "$DRY_RUN" = true ]]; then
        log "INFO" "Running in dry-run mode (no actions will be taken)"
    fi
    
    cache_init
    
    # Get and process teams
    log "INFO" "Retrieving teams from Fleet"
    local teams_response
    if ! teams_response=$(api_get "/api/v1/fleet/teams"); then
        log "ERROR" "Failed to retrieve teams"
        exit 1
    fi
    
    # Check if we have a valid teams response
    if ! echo "$teams_response" | jq -e '.teams' > /dev/null 2>&1; then
        log "ERROR" "Invalid or empty teams response"
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
