#!/system/bin/sh

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================

readonly FLUX_DIR="/data/adb/Flux"
readonly SCRIPTS_DIR="${FLUX_DIR}/scripts"
readonly START_SCRIPT="${SCRIPTS_DIR}/start.sh"
readonly LOG_FILE="${FLUX_DIR}/run/Flux.log"

export LOG_COMPONENT="Service"
export TPROXY_INTERNAL_TOKEN="valid_entry_2026"

# ==============================================================================
# BOOT DETECTION UTILITY
# ==============================================================================

# Wait for the Android system to signal boot completion via getprop
wait_for_boot() {
    log_info "Waiting for system boot completion..."
    
    local boot_wait_count=0
    local MAX_BOOT_WAIT=60
    
    while [ "$boot_wait_count" -lt "$MAX_BOOT_WAIT" ]; do
        # Check property to verify if boot process is finished
        if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            log_info "System boot completed (waited ${boot_wait_count}s)"
            return 0
        fi
        
        sleep 1
        boot_wait_count=$((boot_wait_count + 1))
    done
    
    log_error "Timeout waiting for boot completion after ${MAX_BOOT_WAIT}s"
    return 1
}

# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================

main() {
    log_info "TProxyShell Boot Service Starting"
    
    if ! wait_for_boot; then
        log_error "Boot timeout, attempting to start anyway..."
    fi
    
    sleep 5
    
    if [ ! -f "$START_SCRIPT" ]; then
        log_error "Startup script not found: $START_SCRIPT"
        exit 1
    fi
    
    if [ ! -x "$START_SCRIPT" ]; then
        chmod +x "$START_SCRIPT" 2>/dev/null || {
            log_error "Failed to set executable permission on $START_SCRIPT"
            exit 1
        }
    fi
    
    /system/bin/sh "$START_SCRIPT" start >/dev/null 2>&1 &
    
    log_info "Launching service startup script..."
}

main