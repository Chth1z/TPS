#!/system/bin/sh


SKIPUNZIP=1

# --- Directory Structure ---
readonly FLUX_DIR="/data/adb/Flux"
readonly CONF_DIR="$FLUX_DIR/conf"
readonly BIN_DIR="$FLUX_DIR/bin"
readonly SCRIPTS_DIR="$FLUX_DIR/scripts"
readonly RUN_DIR="$FLUX_DIR/run"
readonly TOOLS_DIR="$FLUX_DIR/tools"

readonly TMP_BACKUP="$FLUX_DIR/Flux_backup_$(date +%s)"

# --- UI Functions ---
ui_print() { echo "$1"; }
ui_error() { ui_print "ERROR: $1"; }
ui_success() { ui_print "√ $1"; }


# --- User Input Handling ---
choose_action() {
    local title="$1"
    local default_action="$2"
    local wait_time=10
    
    ui_print " "
    ui_print "● $title"
    ui_print " "
    ui_print "  Vol [+] : Yes / Keep"
    ui_print "  Vol [-] : No / Reset"
    ui_print " "
    ui_print "  > Waiting for input ($wait_time s)..."

    # Clear input buffer
    while read -r dummy; do :; done < /dev/input/event0 2>/dev/null &
    local clear_pid=$!
    sleep 0.1
    kill "$clear_pid" 2>/dev/null

    local start_time
    start_time=$(date +%s)

    while true; do
        local current_time elapsed
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $wait_time ]; then
            if [ "$default_action" = "true" ]; then
                ui_print "  > Timeout. Default: [Keep Config]"
                return 0
            else
                ui_print "  > Timeout. Default: [Reset Config]"
                return 1
            fi
        fi

        local key_event
        key_event=$(timeout 0.1 getevent -lc 1 2>&1 || true)

        if echo "$key_event" | grep -q "KEY_VOLUMEUP"; then
            ui_print "  > Selected: [Keep Config]"
            return 0
        elif echo "$key_event" | grep -q "KEY_VOLUMEDOWN"; then
            ui_print "  > Selected: [Reset Config]"
            return 1
        fi
    done
}


# --- File Operations ---
backup_config() {
    ui_print "- Checking existing configuration..."
    
    rm -rf "$TMP_BACKUP"
    mkdir -p "$TMP_BACKUP/conf"
    mkdir -p "$TMP_BACKUP/tools"
    
    local count=0
    
    if [ -f "$CONF_DIR/settings.ini" ]; then
        cp -f "$CONF_DIR/settings.ini" "$TMP_BACKUP/conf/"
        count=$((count + 1))
    fi
    
    if [ -f "$CONF_DIR/config.json" ]; then
        cp -f "$CONF_DIR/config.json" "$TMP_BACKUP/conf/"
        count=$((count + 1))
    fi

    if [ -f "$TOOLS_DIR/pref.toml" ]; then
        cp -f "$TOOLS_DIR/pref.toml" "$TMP_BACKUP/tools/"
        count=$((count + 1))
    fi
    
    if [ $count -eq 0 ]; then
        return 1
    fi
    
    ui_print "  > Found $count configuration file(s)"
    return 0
}

restore_config() {
    local keep_mode="$1"
    local suffix=""
    local msg_action=""

    if [ "$keep_mode" = "true" ]; then
        ui_print "- Restoring configuration (Overwrite)..."
        suffix=""
        msg_action="Restored"
    else
        ui_print "- Archiving old configuration (.bak)..."
        suffix=".bak"
        msg_action="Archived as .bak"
    fi
    
    [ ! -d "$TMP_BACKUP" ] && return 1
    
    if [ -f "$TMP_BACKUP/conf/settings.ini" ]; then
        cp -f "$TMP_BACKUP/conf/settings.ini" "$CONF_DIR/settings.ini${suffix}"
        ui_print "  > settings.ini -> $msg_action"
    fi
    
    if [ -f "$TMP_BACKUP/conf/config.json" ]; then
        cp -f "$TMP_BACKUP/conf/config.json" "$CONF_DIR/config.json${suffix}"
        ui_print "  > config.json -> $msg_action"
    fi
    
    if [ -f "$TMP_BACKUP/tools/pref.toml" ]; then
        cp -f "$TMP_BACKUP/tools/pref.toml" "$TOOLS_DIR/pref.toml${suffix}"
        ui_print "  > pref.toml -> $msg_action"
    fi
    
    rm -rf "$TMP_BACKUP"
}


# --- Installation Steps ---
extract_module_files() {
    ui_print "- Extracting module files..."
    
    unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'bin/*' -x 'conf/*' -x 'scripts/*' -x 'tools/*' -d "$MODPATH" >&2 || {
        ui_error "Failed to extract module files"
        return 1
    }
    
    [ -f "$MODPATH/service.sh" ] && set_perm "$MODPATH/service.sh" 0 0 0755
    [ -f "$MODPATH/action.sh" ] && set_perm "$MODPATH/action.sh" 0 0 0755
    
    ui_success "Module files extracted"
    return 0
}

deploy_core_files() {
    ui_print "- Deploying core files to $FLUX_DIR..."
    
    mkdir -p "$FLUX_DIR" "$CONF_DIR" "$RUN_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR" || {
        ui_error "Failed to create directory structure"
        return 1
    }
    
    unzip -o "$ZIPFILE" "bin/*" "scripts/*" "conf/*" "tools/*" -d "$FLUX_DIR" >&2 || {
        ui_error "Failed to extract core files"
        return 1
    }
    
    ui_success "Core files deployed"
    return 0
}

set_file_permissions() {
    ui_print "- Setting file permissions..."
    
    set_perm_recursive "$FLUX_DIR" 0 0 0755 0644 || {
        ui_error "Failed to set base permissions"
        return 1
    }
    
    set_perm_recursive "$BIN_DIR" 0 0 0755 0755
    set_perm_recursive "$SCRIPTS_DIR" 0 0 0755 0755
    
    [ -f "$TOOLS_DIR/jq" ] && set_perm "$TOOLS_DIR/jq" 0 0 0755
    [ -f "$TOOLS_DIR/subconverter" ] && set_perm "$TOOLS_DIR/subconverter" 0 0 0755

    set_perm_recursive "$RUN_DIR" 0 0 0755 0777
    
    ui_success "Permissions set correctly"
    return 0
}

cleanup_old_installation() {
    ui_print "- Cleaning up old version..."
    
    rm -rf "$SCRIPTS_DIR"
    rm -rf "$BIN_DIR"
    rm -rf "$TOOLS_DIR"
    
    rm -f "$RUN_DIR/"*.log
    rm -f "$RUN_DIR/"*.pid
    rm -f "$RUN_DIR/update_timestamp"
    
    ui_print "  > Old version cleaned up"
    return 0
}


# --- Main Installation Flow ---
main() {
    # Step 1: Extract module files
    if ! extract_module_files; then
        ui_error "Installation failed at module extraction"
        exit 1
    fi
    
    # Step 2: Backup Phase
    local HAS_BACKUP=false
    if backup_config; then
        HAS_BACKUP=true
    fi
    
    # Step 3: User Interaction
    local KEEP_CONFIG=false
    
    if [ "$HAS_BACKUP" = true ]; then
        if choose_action "Keep existing config?" "true"; then
            KEEP_CONFIG=true
        else
            KEEP_CONFIG=false
        fi
    else
        ui_print "- No existing configuration found"
        KEEP_CONFIG=false
    fi
    
    # Step 4: Clean up old installation
    cleanup_old_installation
    
    # Step 5: Deploy core files
    if ! deploy_core_files; then
        ui_error "Installation failed at core file deployment"
        exit 1
    fi
    
    # Step 6: Smart Restore
    if [ "$HAS_BACKUP" = true ]; then
        restore_config "$KEEP_CONFIG"
    else
        ui_print "- Using default configuration"
    fi
    
    # Step 7: Set file permissions
    if ! set_file_permissions; then
        ui_error "Installation failed at permission setting"
        exit 1
    fi
    
    # Installation complete message
    ui_print " "
    ui_print " Installation Successful!"
    ui_print " "
    
    if [ "$HAS_BACKUP" = true ]; then
        if [ "$KEEP_CONFIG" = true ]; then
            ui_print "  > Config: Preserved (Active)"
        else
            ui_print "  > Config: Reset (Old files saved as .bak)"
        fi
    else
        ui_print "  > Config: Default"
    fi
    
    ui_print " "
}

main
