#!/system/bin/sh


# Load system configuration
. "/data/adb/Flux/scripts/utils.sh" || {
    echo "ERROR: Cannot load utils"
    exit 1
}

export INTERACTIVE=1
export LOG_COMPONENT="Action"
export TPROXY_INTERNAL_TOKEN="valid_entry_2026"


# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================

main() {
    local action="${1:-toggle}"
    
    [ ! -f "$START_SCRIPT" ] && {
        echo "ERROR: Script not found at $START_SCRIPT"
        exit 1
    }
    
    [ ! -x "$START_SCRIPT" ] && chmod +x "$START_SCRIPT" 2>/dev/null
    
    case "$action" in
        toggle)
            # Check if service is running
			if is_core_running; then
				/system/bin/sh "$START_SCRIPT" stop
			else
				/system/bin/sh "$START_SCRIPT" start
			fi
            ;;
        *)
            echo "Usage: $0 {toggle}"
            exit 1
            ;;
    esac
}

main "$@"