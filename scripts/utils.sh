#!/system/bin/sh


# ==============================================================================
# [ Utility Functions ]
# ==============================================================================

# Check if core is running
is_core_running() {
    local pid_file="$PID_FILE"
    local pid
    
    pid=$(cat "$pid_file" 2>/dev/null) || return 1
    [ -z "$pid" ] && return 1
    echo "$pid" | grep -Eq '^[0-9]+$' || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    netstat -tunlp 2>/dev/null | grep -q ":${PROXY_TCP_PORT}.*LISTEN"
}

# Get core PID
get_core_pid() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    echo "$pid" | grep -Eq '^[0-9]+$' || return 1
    echo "$pid"
}

is_valid_int() {
    local val="$1"
    local min="$2"
    local max="$3"
    
    case "$val" in
        ''|*[!0-9]*) return 1 ;;
    esac
    
    if [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
        return 0
    fi
    return 1
}

validate_int_range() {
    local name="$1"
    local val="$2"
    local min="$3"
    local max="$4"
    
    if ! is_valid_int "$val" "$min" "$max"; then
        log_error "Invalid $name: $val (must be $min-$max)"
        return 1
    fi
    return 0
}

validate_flux_config() {
    log_info "Validating configuration..."
    
    local valid=1
    
    validate_int_range "CORE_TIMEOUT" "$CORE_TIMEOUT" 1 60 || valid=0
    validate_int_range "RETRY_COUNT" "$RETRY_COUNT" 0 10 || valid=0
    validate_int_range "UPDATE_INTERVAL" "$UPDATE_INTERVAL" 60 31536000 || valid=0
    validate_int_range "LOG_LEVEL" "$LOG_LEVEL" 0 3 || valid=0
    validate_int_range "LOG_MAX_SIZE" "$LOG_MAX_SIZE" 10240 104857600 || valid=0
    validate_int_range "PROXY_TCP_PORT" "$PROXY_TCP_PORT" 1 65535 || valid=0
    validate_int_range "PROXY_UDP_PORT" "$PROXY_UDP_PORT" 1 65535 || valid=0
    validate_int_range "DNS_PORT" "$DNS_PORT" 1 65535 || valid=0
    validate_int_range "TABLE_ID" "$TABLE_ID" 1 65535 || valid=0
    validate_int_range "MARK_VALUE" "$MARK_VALUE" 1 2147483647 || valid=0
    validate_int_range "MARK_VALUE6" "$MARK_VALUE6" 1 2147483647 || valid=0
    validate_int_range "PROXY_MODE" "$PROXY_MODE" 0 2 || valid=0
    validate_int_range "DNS_HIJACK_ENABLE" "$DNS_HIJACK_ENABLE" 0 2 || valid=0
    validate_int_range "APP_PROXY_MODE" "$APP_PROXY_MODE" 1 2 || valid=0
    validate_int_range "MAC_PROXY_MODE" "$MAC_PROXY_MODE" 1 2 || valid=0
    
    if [ "$valid" -eq 0 ]; then
        log_error "Configuration validation failed"
        return 1
    fi

    log_info "Configuration valid."
}


# ==============================================================================
# [ Security Guard ]
# ==============================================================================

assert_internal_execution() {
    if [ "${TPROXY_INTERNAL_TOKEN:-}" = "valid_entry_2026" ]; then
        return 0
    fi
    
    echo "Please use 'action.sh' to manage the service."
    exit 1
}


# ==============================================================================
# [ Status Property Management ]
# ==============================================================================

# Priority Convention: Error(3) > Warning(2) > Running/Stopped(1)
PROP_LEVEL=0
PROP_TEXT=""
PROP_DETAIL=""

prop_run()   { set_prop "run"   "$1"; }
prop_stop()  { set_prop "stop"  "$1"; }
prop_warn()  { set_prop "warn"  "$1"; }
prop_error() { set_prop "error" "$1"; }

# Set Status (With Priority Check)
set_prop() {
    local status="$1"
    local detail="${2:-}"
    local current_level=1
    
    case "$status" in
        error)   current_level=3 ;;
        warning) current_level=2 ;;
        *)       current_level=1 ;;
    esac

    if [ "$current_level" -ge "$PROP_LEVEL" ]; then
        PROP_LEVEL="$current_level"
        PROP_TEXT="$status"
        PROP_DETAIL="$detail"
    fi
}

# Commit Status to File (Call only once at the end of the script)
update_description() {
    # Return immediately if no status has been set
    [ "$PROP_LEVEL" -eq 0 ] && return 0

    local pid_info=""
    local desc_text=""
    
    if [ "$PROP_TEXT" = "run" ] && [ -s "$PID_FILE" ]; then
        pid_info="PID: $(cat "$PID_FILE")"
    fi

    case "$PROP_TEXT" in
        run)
            desc_text="🥰 [RUNNING] [${pid_info}]"
            ;;
        warn)
            desc_text="🤔 [WARNING] ${PROP_DETAIL:-Unstable}"
            ;;
        error)
            desc_text="🤯 [ERROR] ${PROP_DETAIL:-Unknown}"
            ;;
        stop)
            desc_text="😴 [STOPPED]"
            ;;
        *)
            desc_text="😇 [UNKNOWN]"
            ;;
    esac

    if [ -f "$PROP_FILE" ]; then
        sed -i -E "s/^description=(🥰|🤔|🤯|😴|😇) \[[A-Z]+\](( PID: [0-9]+)| [^ ]+)? /description=/g" "$PROP_FILE"
        sed -i "s|^description=|description=${desc_text} |g" "$PROP_FILE" || \
            log_warn "Failed to update prop"
    fi
}


# ==============================================================================
# [ Advanced Logging System ]
# ==============================================================================

log_debug() { log "Debug" "$1"; }
log_info()  { log "Info"  "$1"; }
log_warn()  { log "Warn"  "$1"; }
log_error() { log "Error" "$1"; }

# Log levels mapping
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

log() {
    local level="$1"
    local message="$2"
    local timestamp
    local level_score=0
    local current_log_level="$LOG_LEVEL"
    local component="${LOG_COMPONENT:-System}"

    case "$level" in
        Debug) level_score=0 ;;
        Info)  level_score=1 ;;
        Warn)  level_score=2 ;;
        Error) level_score=3 ;;
        *)     level_score=1 ;; # Default to Info behavior
    esac

    [ "$level_score" -lt "$current_log_level" ] && return 0

    timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
    
    if [ "${LOG_ENABLE:-1}" -eq 1 ] && [ -n "$LOG_FILE" ]; then
        if [ ! -d "$RUN_DIR" ]; then
             mkdir -p "$RUN_DIR" 2>/dev/null
        fi
        printf "%s [%s] [%s]: %s\n" "$timestamp" "$component" "$level" "$message" >> "$LOG_FILE" 2>/dev/null
    fi
    
    if [ -t 1 ] || [ "${INTERACTIVE:-0}" -eq 1 ]; then
        printf "[%s]: %s\n" "$timestamp" "$message"
    fi
}


# ==============================================================================
# [ Log Rotation ]
# ==============================================================================

rotate_log() {
    [ ! -f "$LOG_FILE" ] && return 0
    
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    
    if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
        [ -f "${LOG_FILE}.2" ] && mv -f "${LOG_FILE}.2" "${LOG_FILE}.3" 2>/dev/null
        [ -f "${LOG_FILE}.1" ] && mv -f "${LOG_FILE}.1" "${LOG_FILE}.2" 2>/dev/null
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
        
        # Clean old logs (>7 days)
        find "$LOG_DIR" -name "Flux.log.*" -mtime +7 -delete 2>/dev/null || true
    fi
}


# ==============================================================================
# [ Default Settings ]
# ==============================================================================

# Subscription Settings
readonly DEFAULT_SUBSCRIPTION_URL=""
# Shell & System Settings
readonly DEFAULT_LOG_ENABLE=1
readonly DEFAULT_LOG_LEVEL=1
readonly DEFAULT_LOG_MAX_SIZE=1048576
readonly DEFAULT_CORE_TIMEOUT=10
readonly DEFAULT_RETRY_COUNT=3
readonly DEFAULT_UPDATE_INTERVAL=86400
# TProxy Default Settings
readonly DEFAULT_CORE_USER="root"
readonly DEFAULT_CORE_GROUP="root"
readonly DEFAULT_ROUTING_MARK=""
readonly DEFAULT_PROXY_TCP_PORT="1536"
readonly DEFAULT_PROXY_UDP_PORT="1536"
readonly DEFAULT_PROXY_MODE=0
readonly DEFAULT_DNS_HIJACK_ENABLE=1
readonly DEFAULT_DNS_PORT="1053"
# Interface Defaults
readonly DEFAULT_MOBILE_INTERFACE="rmnet_data+"
readonly DEFAULT_WIFI_INTERFACE="wlan0"
readonly DEFAULT_HOTSPOT_INTERFACE="wlan2"
readonly DEFAULT_USB_INTERFACE="rndis+"
# Proxy Scope Defaults
readonly DEFAULT_PROXY_MOBILE=1
readonly DEFAULT_PROXY_WIFI=1
readonly DEFAULT_PROXY_HOTSPOT=0
readonly DEFAULT_PROXY_USB=0
readonly DEFAULT_PROXY_TCP=1
readonly DEFAULT_PROXY_UDP=1
readonly DEFAULT_PROXY_IPV6=0
# Internal Marks & IDs
readonly DEFAULT_MARK_VALUE=20
readonly DEFAULT_MARK_VALUE6=25
readonly DEFAULT_TABLE_ID=2025
# App Proxy Defaults
readonly DEFAULT_APP_PROXY_ENABLE=0
readonly DEFAULT_PROXY_APPS_LIST=""
readonly DEFAULT_BYPASS_APPS_LIST=""
readonly DEFAULT_APP_PROXY_MODE=1
# CN IP Bypass Defaults
readonly DEFAULT_BYPASS_CN_IP=0
readonly DEFAULT_CN_IP_FILE="$RUN_DIR/cn.zone"
readonly DEFAULT_CN_IPV6_FILE="$RUN_DIR/cn_ipv6.zone"
readonly DEFAULT_CN_IP_URL="https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt"
readonly DEFAULT_CN_IPV6_URL="https://ispip.clang.cn/all_cn_ipv6.txt"
# MAC Filter Defaults
readonly DEFAULT_MAC_FILTER_ENABLE=0
readonly DEFAULT_PROXY_MACS_LIST=""
readonly DEFAULT_BYPASS_MACS_LIST=""
readonly DEFAULT_MAC_PROXY_MODE="1


# ==============================================================================
# [ Directory Structure ]
# ==============================================================================
# Structure
readonly FLUX_DIR="/data/adb/Flux"
readonly BIN_DIR="$FLUX_DIR/bin"
readonly CONF_DIR="$FLUX_DIR/conf"
readonly SCRIPTS_DIR="$FLUX_DIR/scripts"
readonly RUN_DIR="$FLUX_DIR/run"
readonly TOOLS_DIR="$FLUX_DIR/tools"
readonly MAGISK_MOD_DIR="/data/adb/modules/TProxyShell"
# Core Files
readonly SING_BOX_BIN="$BIN_DIR/sing-box"
readonly CONFIG_FILE="$CONF_DIR/config.json"
readonly SETTINGS_FILE="$CONF_DIR/settings.ini"
readonly PID_FILE="$RUN_DIR/sing-box.pid"
readonly LOG_FILE="$RUN_DIR/Flux.log"
# Scripts
readonly TPROXY_SCRIPT="$SCRIPTS_DIR/tproxy.sh"
readonly UPDATE_SCRIPT="$SCRIPTS_DIR/update.sh"
readonly START_SCRIPT="$SCRIPTS_DIR/start.sh"
# Temporary Files
readonly TMP_SUB_CONVERTED="$RUN_DIR/sub_temp.json"
readonly TMP_NODES_EXTRACTED="$RUN_DIR/nodes.json"
readonly LAST_UPDATE_FILE="$RUN_DIR/update_timestamp"
readonly GENERATE_FILE="$TOOLS_DIR/generate.ini"
# Module Files
readonly PROP_FILE="$MAGISK_MOD_DIR/module.prop"
# Script-specific files
readonly TEMPLATE_FILE="$TOOLS_DIR/base/singbox.json"
readonly CONFIG_BACKUP="$CONF_DIR/config.json.bak"


# ==============================================================================
# [ Exports & Env ]
# ==============================================================================
# Export for subprocesses
export PATH="$BIN_DIR:/data/adb/magisk:/data/adb/ksu/bin:$PATH"
export FLUX_DIR BIN_DIR CONF_DIR SCRIPTS_DIR RUN_DIR TOOLS_DIR
# Network Configuration
readonly USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"


# ==============================================================================
# [ Config Loading ]
# ==============================================================================

load_flux_config() {
    if [ -f "$SETTINGS_FILE" ]; then
        set -a
        . "$SETTINGS_FILE"
        set +a
    fi
    
    SUBSCRIPTION_URL="${SUBSCRIPTION_URL:-$DEFAULT_SUBSCRIPTION_URL}"
    CORE_TIMEOUT="${CORE_TIMEOUT:-$DEFAULT_CORE_TIMEOUT}"
    UPDATE_INTERVAL="${UPDATE_INTERVAL:-$DEFAULT_UPDATE_INTERVAL}"
    RETRY_COUNT="${RETRY_COUNT:-$DEFAULT_RETRY_COUNT}"
    LOG_ENABLE="${LOG_ENABLE:-$DEFAULT_LOG_ENABLE}"
    LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"
    LOG_MAX_SIZE="${LOG_MAX_SIZE:-$DEFAULT_LOG_MAX_SIZE}"
    CORE_USER="${CORE_USER:-$DEFAULT_CORE_USER}"
    CORE_GROUP="${CORE_GROUP:-$DEFAULT_CORE_GROUP}"
    ROUTING_MARK="${ROUTING_MARK:-$DEFAULT_ROUTING_MARK}"
    PROXY_TCP_PORT="${PROXY_TCP_PORT:-$DEFAULT_PROXY_TCP_PORT}"
    PROXY_UDP_PORT="${PROXY_UDP_PORT:-$DEFAULT_PROXY_UDP_PORT}"
    PROXY_MODE="${PROXY_MODE:-$DEFAULT_PROXY_MODE}"
    DNS_HIJACK_ENABLE="${DNS_HIJACK_ENABLE:-$DEFAULT_DNS_HIJACK_ENABLE}"
    DNS_PORT="${DNS_PORT:-$DEFAULT_DNS_PORT}"
    MOBILE_INTERFACE="${MOBILE_INTERFACE:-$DEFAULT_MOBILE_INTERFACE}"
    WIFI_INTERFACE="${WIFI_INTERFACE:-$DEFAULT_WIFI_INTERFACE}"
    HOTSPOT_INTERFACE="${HOTSPOT_INTERFACE:-$DEFAULT_HOTSPOT_INTERFACE}"
    USB_INTERFACE="${USB_INTERFACE:-$DEFAULT_USB_INTERFACE}"
    PROXY_MOBILE="${PROXY_MOBILE:-$DEFAULT_PROXY_MOBILE}"
    PROXY_WIFI="${PROXY_WIFI:-$DEFAULT_PROXY_WIFI}"
    PROXY_HOTSPOT="${PROXY_HOTSPOT:-$DEFAULT_PROXY_HOTSPOT}"
    PROXY_USB="${PROXY_USB:-$DEFAULT_PROXY_USB}"
    PROXY_TCP="${PROXY_TCP:-$DEFAULT_PROXY_TCP}"
    PROXY_UDP="${PROXY_UDP:-$DEFAULT_PROXY_UDP}"
    PROXY_IPV6="${PROXY_IPV6:-$DEFAULT_PROXY_IPV6}"
    MARK_VALUE="${MARK_VALUE:-$DEFAULT_MARK_VALUE}"
    MARK_VALUE6="${MARK_VALUE6:-$DEFAULT_MARK_VALUE6}"
    TABLE_ID="${TABLE_ID:-$DEFAULT_TABLE_ID}"
    APP_PROXY_ENABLE="${APP_PROXY_ENABLE:-$DEFAULT_APP_PROXY_ENABLE}"
    PROXY_APPS_LIST="${PROXY_APPS_LIST:-$DEFAULT_PROXY_APPS_LIST}"
    BYPASS_APPS_LIST="${BYPASS_APPS_LIST:-$DEFAULT_BYPASS_APPS_LIST}"
    APP_PROXY_MODE="${APP_PROXY_MODE:-$DEFAULT_APP_PROXY_MODE}"
    BYPASS_CN_IP="${BYPASS_CN_IP:-$DEFAULT_BYPASS_CN_IP}"
    CN_IP_FILE="${CN_IP_FILE:-$DEFAULT_CN_IP_FILE}"
    CN_IPV6_FILE="${CN_IPV6_FILE:-$DEFAULT_CN_IPV6_FILE}"
    CN_IP_URL="${CN_IP_URL:-$DEFAULT_CN_IP_URL}"
    CN_IPV6_URL="${CN_IPV6_URL:-$DEFAULT_CN_IPV6_URL}"
    MAC_FILTER_ENABLE="${MAC_FILTER_ENABLE:-$DEFAULT_MAC_FILTER_ENABLE}"
    PROXY_MACS_LIST="${PROXY_MACS_LIST:-$DEFAULT_PROXY_MACS_LIST}"
    BYPASS_MACS_LIST="${BYPASS_MACS_LIST:-$DEFAULT_BYPASS_MACS_LIST}"
    MAC_PROXY_MODE="${MAC_PROXY_MODE:-$DEFAULT_MAC_PROXY_MODE}"
}
