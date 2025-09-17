#!/usr/bin/env bash
# fleet-retry-controller.sh
# Purpose: Automatically retry Fleet policy automations (scripts/software installs) on failing hosts
# Requirements: bash, curl, jq
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
SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="fleet-retry-controller"

# Environment validation
: "${FLEET_URL:?Error: FLEET_URL environment variable is required}"
: "${FLEET_TOKEN:?Error: FLEET_TOKEN environment variable is required}"

# Default configuration
API_SLEEP="${API_SLEEP:-0.3}"                    # Sleep between API calls
MAX_RETRIES="${MAX_RETRIES:-3}"                  # Maximum retry attempts
CACHE_FILE="${CACHE_FILE:-$HOME/.fleet_retry_cache.db}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"                   # DEBUG, INFO, WARN, ERROR
DRY_RUN=false
VERBOSE=false
TEAMS_FILTER=""
EXCLUDE_POLICIES=""
LOG_FILE=""

# Backoff schedule (seconds): 30min -> 2h -> 6h -> 24h
BACKOFF_SCHEDULE=(1800 7200 21600 86400)

# Statistics tracking
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

# Utility functions
now_ts() { date +%s; }
iso_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(iso_timestamp)"
    
    # Check log level
    case "$LOG_LEVEL" in
        DEBUG) [[ "$level" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]] || return ;;
        INFO)  [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]] || return ;;
        WARN)  [[ "$level" =~ ^(WARN|ERROR)$ ]] || return ;;
        ERROR) [[ "$level" = "ERROR" ]] || return ;;
    esac
    
    local log_line="[$timestamp] $level: $message"
    echo "$log_line" >&2
    
    # Also log to file if specified
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_line" >> "$LOG_FILE"
    fi
}

show_usage() {
    cat << EOF
Fleet Policy Remediation Controller v$SCRIPT_VERSION

Usage: $0 [OPTIONS]

OPTIONS:
    --dry-run                    Preview actions without executing
    --verbose, -v                Enable verbose logging
    --config=FILE                Load configuration from file
    --teams=LIST                 Comma-separated team names to process
    --exclude-policies=LIST      Comma-separated policy names to exclude
    --max-retries=N              Maximum retry attempts (default: $MAX_RETRIES)
    --log-file=FILE              Log to file in addition to stderr
    --help, -h                   Show this help message
    --version                    Show version information

ENVIRONMENT VARIABLES:
    FLEET_URL        Fleet server URL (required)
    FLEET_TOKEN      Fleet API token (required)
    API_SLEEP        Sleep between API calls (default: $API_SLEEP)
    MAX_RETRIES      Maximum retry attempts (default: $MAX_RETRIES)
    LOG_LEVEL        Logging level: DEBUG/INFO/WARN/ERROR (default: $LOG_LEVEL)

EXAMPLES:
    # Preview what would be retried
    $0 --dry-run
    
    # Execute with verbose logging
    $0 --verbose --log-file=/var/log/fleet-retry.log
    
    # Process only specific teams
    $0 --teams="Production,Staging"
    
    # Exclude problematic policies
    $0 --exclude-policies="Legacy Script,Broken Install"

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --config=*)
                local config_file="${1#*=}"
                if [[ -f "$config_file" ]]; then
                    # shellcheck source=/dev/null
                    source "$config_file"
                else
                    log ERROR "Configuration file not found: $config_file"
                    exit 1
                fi
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
                    log ERROR "Invalid max-retries value: $MAX_RETRIES"
                    exit 1
                fi
                shift
                ;;
            --log-file=*)
                LOG_FILE="${1#*=}"
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            --version)
                echo "$SCRIPT_NAME v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# API helper functions
api_call() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    local response_file
    
    response_file=$(mktemp)
    
    local curl_args=(
        -sfS
        --retry 3
        --retry-delay 1
        --connect-timeout 30
        --max-time 120
        -H "Authorization: Bearer $FLEET_TOKEN"
        -H "Content-Type: application/json"
        -o "$response_file"
    )
    
    if [[ "$method" = "POST" && -n "$data" ]]; then
        curl_args+=(-X POST -d "$data")
    fi
    
    if curl "${curl_args[@]}" "$FLEET_URL$path"; then
        cat "$response_file"
        rm -f "$response_file"
        sleep "$API_SLEEP"
        return 0
    else
        local exit_code=$?
        rm -f "$response_file"
        ((STATS[api_errors]++))
        log ERROR "API call failed: $method $path (exit code: $exit_code)"
        return $exit_code
    fi
}

api_get() {
    api_call "GET" "$@"
}

api_post() {
    if [[ "$DRY_RUN" = true ]]; then
        log INFO "[DRY-RUN] Would POST to $1 with data: $2"
        return 0
    fi
    api_call "POST" "$@"
}

# Cache management functions
cache_init() {
    touch "$CACHE_FILE"
    # Clean up old entries (older than 7 days)
    local cutoff=$(($(now_ts) - 604800))
    if [[ -f "$CACHE_FILE" ]]; then
        awk -F'|' -v cutoff="$cutoff" '$2 >= cutoff' "$CACHE_FILE" > "$CACHE_FILE.tmp" || true
        mv "$CACHE_FILE.tmp" "$CACHE_FILE"
    fi
}

cache_get() {
    local key="$1"
    grep -E "^${key//\//\\/}\\|" "$CACHE_FILE" 2>/dev/null || true
}

cache_upsert() {
    local key="$1"
    local timestamp="$2"
    local retry_count="$3"
    
    # Remove existing entry
    grep -vE "^${key//\//\\/}\\|" "$CACHE_FILE" 2>/dev/null > "$CACHE_FILE.tmp" || true
    # Add new entry
    printf "%s|%s|%s\n" "$key" "$timestamp" "$retry_count" >> "$CACHE_FILE.tmp"
    mv "$CACHE_FILE.tmp" "$CACHE_FILE"
}

get_backoff_seconds() {
    local retry_count="$1"
    local index=$((retry_count - 1))
    
    if [[ $index -lt 0 ]]; then
        echo 0
    elif [[ $index -ge ${#BACKOFF_SCHEDULE[@]} ]]; then
        echo "${BACKOFF_SCHEDULE[-1]}"
    else
        echo "${BACKOFF_SCHEDULE[$index]}"
    fi
}

should_retry() {
    local cache_key="$1"
    local cache_entry
    cache_entry=$(cache_get "$cache_key")
    
    if [[ -z "$cache_entry" ]]; then
        log DEBUG "No cache entry for $cache_key, proceeding with retry"
        return 0  # No cache entry, proceed
    fi
    
    local last_timestamp retry_count
    IFS='|' read -r _ last_timestamp retry_count <<< "$cache_entry"
    
    if [[ $retry_count -ge $MAX_RETRIES ]]; then
        log DEBUG "Max retries ($MAX_RETRIES) reached for $cache_key"
        ((STATS[skipped_max_retries]++))
        return 1  # Max retries reached
    fi
    
    local backoff_seconds
    backoff_seconds=$(get_backoff_seconds "$retry_count")
    local elapsed=$(($(now_ts) - last_timestamp))
    
    if [[ $elapsed -lt $backoff_seconds ]]; then
        local remaining=$((backoff_seconds - elapsed))
        log DEBUG "Backoff period not elapsed for $cache_key (${remaining}s remaining)"
        ((STATS[skipped_backoff]++))
        return 1  # Still in backoff period
    fi
    
    log DEBUG "Ready to retry $cache_key (attempt $((retry_count + 1)))"
    return 0  # Ready to retry
}

# Fleet API interaction functions
run_script_on_host() {
    local host_id="$1"
    local script_id="$2"
    local policy_name="$3"
    
    log INFO "Running script $script_id on host $host_id for policy '$policy_name'"
    
    local payload
    payload=$(jq -n \
        --argjson host_id "$host_id" \
        --argjson script_id "$script_id" \
        '{host_id: $host_id, script_id: $script_id}')
    
    if api_post "/api/v1/fleet/scripts/run" "$payload" >/dev/null; then
        log INFO "Successfully triggered script $script_id on host $host_id"
        ((STATS[scripts_triggered]++))
        return 0
    else
        log ERROR "Failed to trigger script $script_id on host $host_id"
        return 1
    fi
}

install_software_on_host() {
    local host_id="$1"
    local software_title_id="$2"
    local policy_name="$3"
    
    log INFO "Installing software $software_title_id on host $host_id for policy '$policy_name'"
    
    if api_post "/api/v1/fleet/hosts/$host_id/software/$software_title_id/install" "{}" >/dev/null; then
        log INFO "Successfully triggered software install $software_title_id on host $host_id"
        ((STATS[software_triggered]++))
        return 0
    else
        log ERROR "Failed to trigger software install $software_title_id on host $host_id"
        return 1
    fi
}

should_process_team() {
    local team_name="$1"
    
    if [[ -z "$TEAMS_FILTER" ]]; then
        return 0  # No filter, process all teams
    fi
    
    # Check if team name is in the comma-separated filter list
    local IFS=','
    for filter_team in $TEAMS_FILTER; do
        if [[ "$team_name" = "$filter_team" ]]; then
            return 0
        fi
    done
    
    return 1  # Team not in filter list
}

should_process_policy() {
    local policy_name="$1"
    
    if [[ -z "$EXCLUDE_POLICIES" ]]; then
        return 0  # No exclusions, process all policies
    fi
    
    # Check if policy name is in the comma-separated exclusion list
    local IFS=','
    for exclude_policy in $EXCLUDE_POLICIES; do
        if [[ "$policy_name" = "$exclude_policy" ]]; then
            return 1  # Policy is excluded
        fi
    done
    
    return 0  # Policy not excluded
}

process_failing_hosts() {
    local team_id="$1"
    local team_name="$2"
    local policy_id="$3"
    local policy_name="$4"
    local script_id="$5"
    local software_title_id="$6"
    
    # Check if policy has any automation configured
    if [[ -z "$script_id" && -z "$software_title_id" ]]; then
        log DEBUG "Policy '$policy_name' has no automation configured, skipping"
        return 0
    fi
    
    log DEBUG "Processing failing hosts for policy '$policy_name' (ID: $policy_id)"
    
    # Get all hosts for the team and check their policy status
    local page=0
    local per_page=100
    local processed_hosts=0
    
    while true; do
        local hosts_response
        local query_params="page=$page&per_page=$per_page"
        
        if [[ "$team_id" != "global" ]]; then
            query_params="$query_params&team_id=$team_id"
        fi
        
        if ! hosts_response=$(api_get "/api/v1/fleet/hosts?$query_params"); then
            log ERROR "Failed to retrieve hosts for team $team_name"
            break
        fi
        
        local hosts_count
        hosts_count=$(echo "$hosts_response" | jq '.hosts | length')
        
        if [[ "$hosts_count" -eq 0 ]]; then
            break  # No more hosts
        fi
        
        # Process each host
        echo "$hosts_response" | jq -c '.hosts[]' | while read -r host; do
            local host_id
            host_id=$(echo "$host" | jq -r '.id')
            
            # Check if this host is failing the policy
            local policy_status
            policy_status=$(echo "$host" | jq -r --argjson pid "$policy_id" '.policies[] | select(.id == $pid) | .response // "unknown"')
            
            if [[ "$policy_status" != "fail" ]]; then
                continue  # Host is not failing this policy
            fi
            
            ((processed_hosts++))
            ((STATS[hosts_processed]++))
            
            local cache_key="${host_id}:${policy_id}:${team_id}"
            
            if ! should_retry "$cache_key"; then
                continue  # Skip due to backoff or max retries
            fi
            
            # Get current retry count for cache update
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
            elif [[ -n "$software_title_id" && "$software_title_id" != "null" ]]; then
                if install_software_on_host "$host_id" "$software_title_id" "$policy_name"; then
                    success=true
                fi
            fi
            
            # Update cache with new attempt
            cache_upsert "$cache_key" "$(now_ts)" "$((retry_count + 1))"
            
            if [[ "$success" = false ]]; then
                log WARN "Remediation failed for host $host_id, policy '$policy_name'"
            fi
        done
        
        page=$((page + 1))
    done
    
    if [[ $processed_hosts -gt 0 ]]; then
        log INFO "Processed $processed_hosts failing hosts for policy '$policy_name'"
    fi
}

process_team_policies() {
    local team_id="$1"
    local team_name="$2"
    
    if ! should_process_team "$team_name"; then
        log DEBUG "Skipping team '$team_name' due to filter"
        return 0
    fi
    
    log INFO "Processing policies for team: $team_name (ID: $team_id)"
    ((STATS[teams_processed]++))
    
    # Get policies for the team
    local policies_endpoint
    if [[ "$team_id" = "global" ]]; then
        policies_endpoint="/api/v1/fleet/policies"
    else
        policies_endpoint="/api/v1/fleet/teams/$team_id/policies"
    fi
    
    local policies_response
    if ! policies_response=$(api_get "$policies_endpoint"); then
        log ERROR "Failed to retrieve policies for team $team_name"
        return 1
    fi
    
    local policies_count
    policies_count=$(echo "$policies_response" | jq '.policies | length')
    log INFO "Found $policies_count policies in team $team_name"
    
    # Process each policy
    echo "$policies_response" | jq -c '.policies[]' | while read -r policy; do
        local policy_id policy_name script_id software_title_id
        policy_id=$(echo "$policy" | jq -r '.id')
        policy_name=$(echo "$policy" | jq -r '.name')
        
        if ! should_process_policy "$policy_name"; then
            log DEBUG "Skipping excluded policy '$policy_name'"
            continue
        fi
        
        ((STATS[policies_processed]++))
        
        # Extract automation configuration
        # Note: The exact structure may vary depending on Fleet version
        script_id=$(echo "$policy" | jq -r '.run_script.id // .automation.run_script.id // empty')
        software_title_id=$(echo "$policy" | jq -r '.install_software.software_title_id // .automation.install_software.software_title_id // empty')
        
        log DEBUG "Policy '$policy_name': script_id=$script_id, software_title_id=$software_title_id"
        
        process_failing_hosts "$team_id" "$team_name" "$policy_id" "$policy_name" "$script_id" "$software_title_id"
    done
}

show_statistics() {
    log INFO "=== Execution Statistics ==="
    log INFO "Teams processed: ${STATS[teams_processed]}"
    log INFO "Policies processed: ${STATS[policies_processed]}"
    log INFO "Hosts processed: ${STATS[hosts_processed]}"
    log INFO "Scripts triggered: ${STATS[scripts_triggered]}"
    log INFO "Software installs triggered: ${STATS[software_triggered]}"
    log INFO "Skipped (backoff): ${STATS[skipped_backoff]}"
    log INFO "Skipped (max retries): ${STATS[skipped_max_retries]}"
    log INFO "API errors: ${STATS[api_errors]}"
}

# Signal handlers for graceful shutdown
cleanup() {
    log INFO "Received interrupt signal, shutting down gracefully..."
    show_statistics
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main execution function
main() {
    log INFO "Starting Fleet Policy Remediation Controller v$SCRIPT_VERSION"
    
    if [[ "$DRY_RUN" = true ]]; then
        log INFO "Running in DRY-RUN mode - no actions will be executed"
    fi
    
    cache_init
    
    # Get all teams
    local teams_response
    if ! teams_response=$(api_get "/api/v1/fleet/teams"); then
        log ERROR "Failed to retrieve teams"
        exit 1
    fi
    
    local teams_count
    teams_count=$(echo "$teams_response" | jq '.teams | length')
    log INFO "Found $teams_count teams"
    
    # Process global policies first (if any exist)
    log DEBUG "Processing global policies"
    process_team_policies "global" "Global"
    
    # Process each team
    echo "$teams_response" | jq -c '.teams[]' | while read -r team; do
        local team_id team_name
        team_id=$(echo "$team" | jq -r '.id')
        team_name=$(echo "$team" | jq -r '.name')
        
        process_team_policies "$team_id" "$team_name"
    done
    
    show_statistics
    log INFO "Fleet Policy Remediation Controller completed successfully"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    main
fi