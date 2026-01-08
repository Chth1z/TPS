#!/system/bin/sh


# ==============================================================================
# TProxyShell Service Manager (start.sh)
# Description: Manages sing-box core lifecycle and TProxy firewall rules
# ==============================================================================

# ------------------------------------------------------------------------------
# [ Load Dependencies ]
# ------------------------------------------------------------------------------
. "$(dirname "$(readlink -f "$0")")/utils.sh"
# Ensure script is called via action.sh/internal mechanism
assert_internal_execution
# Set log component name for logging function
export LOG_COMPONENT="Manager"


# ==============================================================================
# [ Environment & Resource Initialization ]
# ==============================================================================

# Initialize runtime environment and rotate logs
init_environment() {
    # Create run directory if missing
    if [ ! -d "$RUN_DIR" ]; then
        mkdir -p "$RUN_DIR" || {
            log_error "Failed to create run directory: $RUN_DIR"
            prop_error "Init Failed"
            return 1
        }
        chmod 0755 "$RUN_DIR"
    fi
    
    if ! rotate_log; then
        log_error "Failed to rotate log"
        prop_error "Init Failed"
        return 1
    fi
    
    log_info "Environment initialized"
    return 0
}

# Check integrity of required files and permissions
check_resource_integrity() {
    local required_files="$SING_BOX_BIN $CONFIG_FILE $SETTINGS_FILE $TPROXY_SCRIPT $UPDATE_SCRIPT"
    local missing_files=""
    
    for file in $required_files; do
        if [ ! -f "$file" ]; then
            missing_files="$missing_files $(basename "$file")"
        fi
    done
    
    if [ -n "$missing_files" ]; then
        prop_error "Missing: $missing_files"
        return 1
    fi
    
    local executable_files="$SING_BOX_BIN $TPROXY_SCRIPT $UPDATE_SCRIPT"
    
    for file in $executable_files; do
        if [ ! -x "$file" ]; then
            chmod +x "$file" 2>/dev/null
            if [ ! -x "$file" ]; then
                prop_error "No Permission: $file"
                return 1
            fi
            log_debug "Fixed permission for $file"
        fi
    done
    
    log_info "Resource integrity check passed"
    return 0
}


# ==============================================================================
# [ Update Management ]
# ==============================================================================

# Determine if subscription update is required based on timestamp
is_update_due() {
    # If no timestamp file exists, update is needed
    [ ! -f "$LAST_UPDATE_FILE" ] && return 0
    
    local last_time
    last_time=$(cat "$LAST_UPDATE_FILE" 2>/dev/null)
    
    # If file is empty or invalid, update is needed
    [ -z "$last_time" ] && return 0
    
    local current_time
    current_time=$(date +%s)
    
    # Check if time elapsed exceeds interval
    if [ $((current_time - last_time)) -ge "$UPDATE_INTERVAL" ]; then
        return 0 # Update needed
    else
        return 1 # Recently updated
    fi
}

# Run update script in background with timeout monitoring
execute_update() {
    if is_update_due; then
        log_info "Updating configuration..."
        
        # Run update silently with timeout
        local update_pid update_result
        
        sh "$UPDATE_SCRIPT" &
        update_pid=$!
        
        local waited=0
        while [ $waited -lt "$UPDATE_TIMEOUT" ]; do
            # Check if update process is still running
            if ! kill -0 "$update_pid" 2>/dev/null; then
                # Process finished, get exit code
                wait "$update_pid" 2>/dev/null
                update_result=$?
                
                if [ $update_result -eq 0 ]; then
                    log_info "Configuration update successful"
                    date +%s > "$LAST_UPDATE_FILE"  # Record success time
                    return 0
                else
                    log_warn "Configuration update failed"
                    return 1
                fi
            fi
            
            sleep 1
            waited=$((waited + 1))
        done
        
        # Timeout reached, kill update process
        log_warn "Update timeout after ${UPDATE_TIMEOUT}s, terminating..."
        kill -9 "$update_pid" 2>/dev/null
        return 1
    else
        log_info "Skipping update (updated within ${UPDATE_INTERVAL}s)."
    fi
}


# ==============================================================================
# [ Core Process Management ]
# ==============================================================================

# Validate sing-box JSON configuration syntax
validate_singbox_config() {
    local check_output check_result
    
    # Run sing-box config check
    check_output=$("$SING_BOX_BIN" check -c "$CONFIG_FILE" -D "$RUN_DIR" 2>&1)
    check_result=$?
    
    if [ $check_result -ne 0 ]; then
        log_error "Configuration validation failed!"
        log_error "Details: $check_output"
        prop_error "Invalid Config"
        return 1
    fi
    
    log_info "Configuration validation passed"
    return 0
}

# Start sing-box core process and verify PID
start_core() {
    log_info "Starting sing-box core..."
    
    nohup "$SING_BOX_BIN" run \
        -c "$CONFIG_FILE" \
        -D "$RUN_DIR" \
        >/dev/null 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    local start_wait_count=0
    while [ $start_wait_count -lt "$CORE_TIMEOUT" ]; do
        
        if is_core_running; then
            log_info "Core started successfully (PID: $pid, Port: $PROXY_TCP_PORT)"
            return 0
        fi
        
        sleep 0.5
        start_wait_count=$((start_wait_count + 1))
    done
    
    log_error "Core process died during startup"
    prop_error "Core Start Failed"
    stop_core
    return 1
}

# Stop sing-box core process gracefully (SIGTERM -> SIGKILL)
stop_core() {
    if [ -s "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Sending SIGTERM to PID $pid"
            kill "$pid" 2>/dev/null
            
            local stop_wait_count=0
            while kill -0 "$pid" 2>/dev/null && [ $stop_wait_count -lt "$CORE_TIMEOUT" ]; do
                sleep 0.5
                stop_wait_count=$((stop_wait_count + 1))
            done
            
            if kill -0 "$pid" 2>/dev/null; then
                log_warn "Process $pid did not stop gracefully, sending SIGKILL"
                kill -9 "$pid" 2>/dev/null
                sleep 0.5
            fi
        fi
    else
        pkill -9 -f "sing-box.*run.*$CONFIG_FILE" 2>/dev/null
    fi
    
    rm -f "$PID_FILE"
    log_info "Core stopped"
}


# ==============================================================================
# [ TProxy & Firewall Management ]
# ==============================================================================

# Execute TProxy script with animation (if interactive)
execute_tproxy() {
    local action="$1"
    local desc_action="Running TProxy"
    
    # Beautify action name for display
    [ "$action" = "start" ] && desc_action="Applying TProxy rules"
    [ "$action" = "stop" ] && desc_action="Clearing TProxy rules"

    log_info "Executing TProxy script: $action"
    
    [ ! -f "$TPROXY_SCRIPT" ] && {
        log_error "TProxy script not found: $TPROXY_SCRIPT"
        return 1
    }
    
    sh "$TPROXY_SCRIPT" "$action" >/dev/null 2>&1 &
    local pid=$!
    
    if [ "${INTERACTIVE:-0}" -eq 1 ]; then
        local spin='-\|/'
        local i=0
        
        while kill -0 "$pid" 2>/dev/null; do
            i=$(( (i+1) %4 ))
            # Print spinner on current line
            printf "\r %s... %s" "$desc_action" "${spin:$i:1}"
            sleep 0.5
        done
        
        printf "\r%-60s\r" " "
    fi
    
    wait "$pid"
    local ret=$?
    
    if [ $ret -eq 0 ]; then
        log_info "TProxy $action successfully"
        return 0
    else
        log_error "TProxy $action failed (exit code: $ret)"
        prop_error "TProxy $action failed"
        return 1
    fi
}


# ==============================================================================
# [ Main Service Operations ]
# ==============================================================================

# Sequence: Stop TProxy/Core -> Update -> Validate -> Start Core -> Start TProxy
start_service_sequence() {
    init_environment || exit 1
    check_resource_integrity || exit 1
    
    execute_tproxy "stop" >/dev/null 2>&1 || true
    stop_core >/dev/null 2>&1 || true
    
    execute_update || log_warn "Update failed, attempting to start with existing config"
    
    validate_singbox_config || exit 1
    start_core || exit 1
   
    if ! execute_tproxy "start"; then
        stop_service_sequence >/dev/null 2>&1 || true
        exit 1
    fi
    
    log_info "Service start successfully"
    prop_run
}

# Sequence: Stop TProxy -> Stop Core
stop_service_sequence() {
    execute_tproxy "stop" || log_warn "TProxy cleanup encountered errors"
    stop_core || true
    
    log_info "Service stop successfully"
    prop_stop
}


# ==============================================================================
# [ Entry Point ]
# ==============================================================================

main() {
    load_flux_config
    validate_flux_config
    
    trap 'update_description' EXIT
    
    local action="${1:-}"
    
    case "$action" in
        start)
            start_service_sequence
            ;;
        stop)
            stop_service_sequence
            ;;
        *)
            echo "Usage: $0 {start|stop}"
            exit 1
            ;;
    esac
}

main "$@"