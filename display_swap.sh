#!/usr/bin/env bash
LOGFILE="$HOME/.config/userscripts/log.log"

mkdir -p "$(dirname "$LOGFILE")"

get_virtual_connector_from_cmdline() {
    # Extract connector from drm.edid_firmware=<CONNECTOR>:edid/...
    local token
    token=$(grep -o 'drm.edid_firmware=[^ ]*' /proc/cmdline | tail -n1 || true)
    if [ -z "$token" ]; then
        echo ""; return 0
    fi
    echo "${token#drm.edid_firmware=}" | awk -F: '{print $1}'
}

get_output_id_by_name() {
    local name="$1"
    kscreen-doctor --json | jq -r --arg N "$name" '.outputs[] | select(.name==$N) | .id' | head -n1
}

# Parse a mode spec like 1920x1080@60 into W H Hz
parse_mode_spec() {
    local spec="$1"
    if echo "$spec" | grep -Eq '^[0-9]+x[0-9]+@[0-9]+'; then
        local W=$(echo "$spec" | cut -dx -f1)
        local rest=$(echo "$spec" | cut -dx -f2)
        local H=$(echo "$rest" | cut -d@ -f1)
        local Hz=$(echo "$rest" | cut -d@ -f2)
        echo "$W $H $Hz"
    else
        echo ""
    fi
}

log_debug_env () {
    echo "==================== DEBUG ENV START ====================" >> "$LOGFILE"
    echo "DEBUG: Timestamp: $(date)" >> "$LOGFILE"
    echo "DEBUG: whoami: $(whoami)" >> "$LOGFILE"
    echo "DEBUG: PWD: $PWD" >> "$LOGFILE"
    echo "DEBUG: XDG_SESSION_TYPE: $XDG_SESSION_TYPE" >> "$LOGFILE"
    echo "DEBUG: DISPLAY: $DISPLAY" >> "$LOGFILE"
    echo "DEBUG: WAYLAND_DISPLAY: $WAYLAND_DISPLAY" >> "$LOGFILE"
    echo "DEBUG: Parent process: $(ps -p $PPID -o comm= 2>/dev/null || echo 'unknown')" >> "$LOGFILE"
    echo "DEBUG: kscreen-doctor outputs BEFORE:" >> "$LOGFILE"
    kscreen-doctor --json 2>&1 | jq -r '.outputs[] | "id: \(.id) name: \(.name) enabled: \(.enabled) primary: \(.primary)"' >> "$LOGFILE" 2>&1 || echo "kscreen-doctor --json failed" >> "$LOGFILE"
    echo "==================== DEBUG ENV END ====================" >> "$LOGFILE"
}

run_kscreen_doctor () {
    CMD="$1"
    echo "==================== KSCREEN COMMAND START ====================" >> "$LOGFILE"
    echo "kscreen-doctor: Running command: $CMD" >> "$LOGFILE"
    echo "kscreen-doctor: Timestamp: $(date)" >> "$LOGFILE"
    
    OUT=$(eval "$CMD" 2>&1)
    RET=$?
    
    echo "kscreen-doctor: Exit code: $RET" >> "$LOGFILE"
    if [ $RET -eq 0 ]; then
        echo "kscreen-doctor: SUCCESS" >> "$LOGFILE"
    else
        echo "kscreen-doctor: FAILED" >> "$LOGFILE"
    fi
    echo "kscreen-doctor: Output/Error:" >> "$LOGFILE"
    echo "$OUT" >> "$LOGFILE"
    echo "==================== KSCREEN COMMAND END ====================" >> "$LOGFILE"
    
    return $RET
}

# Find a mode id on a given output matching the provided resolution and ~60Hz
find_mode_id_60hz () {
    local out_id="$1"
    local w="$2"
    local h="$3"
    kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out_id" --argjson W "$w" --argjson H "$h" '
      .outputs[] | select(.id==($id|tonumber)) | .modes[]
      | select((.size.width==$W and .size.height==$H) and ((.refreshRate|tostring|startswith("60")) or (.name? // "" | test("@60(\\.\\d+)?$"))))
      | .id' 2>/dev/null | head -n1
}

# Pick a conservative 60Hz mode for the virtual output (prefer 1920x1080, then 2560x1440, else any 60Hz)
pick_virtual_safe_mode () {
    local virt_id="$1"
    local mode_id=""
    # Prefer 1920x1080@60
    mode_id=$(find_mode_id_60hz "$virt_id" 1920 1080)
    if [ -z "$mode_id" ]; then
        # Try 2560x1440@60
        mode_id=$(find_mode_id_60hz "$virt_id" 2560 1440)
    fi
    if [ -z "$mode_id" ]; then
        # Fallback: any mode with @60
        mode_id=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$virt_id" '.outputs[] | select(.id==($id|tonumber)) | .modes[] | select((.refreshRate|tostring|startswith("60")) or (.name? // "" | test("@60(\\.\\d+)?$"))) | .id' 2>/dev/null | head -n1)
    fi
    echo "$mode_id"
}

# Find a mode id by WxH@Hz for a given output id
find_mode_id_by_spec() {
    local out_id="$1"; local W="$2"; local H="$3"; local Hz="$4"
    # Pass 1: exact name contains @Hz
    local id
    id=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out_id" --argjson W "$W" --argjson H "$H" --arg Hz "$Hz" '
        .outputs[] | select(.id==($id|tonumber)) | .modes[]
        | select(.size.width==$W and .size.height==$H and ((.name? // "") | test("@\($Hz)(\\.\\d+)?$")))
        | .id' 2>/dev/null | head -n1)
    if [ -n "$id" ]; then echo "$id"; return 0; fi
    # Pass 2: numeric refreshRate starts with Hz (string compare)
    id=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out_id" --argjson W "$W" --argjson H "$H" --arg Hz "$Hz" '
        .outputs[] | select(.id==($id|tonumber)) | .modes[]
        | select(.size.width==$W and .size.height==$H and ((.refreshRate|tostring) | startswith($Hz)))
        | .id' 2>/dev/null | head -n1)
    if [ -n "$id" ]; then echo "$id"; return 0; fi
    # Pass 3: any matching WxH (fallback)
    id=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out_id" --argjson W "$W" --argjson H "$H" '
        .outputs[] | select(.id==($id|tonumber)) | .modes[]
        | select(.size.width==$W and .size.height==$H) | .id' 2>/dev/null | head -n1)
    echo "$id"
}

# Set output mode by spec string like 1920x1080@60. Returns 0 on success.
set_output_mode_by_spec() {
    local out_id="$1"; local spec="$2"
    local parsed; parsed=$(parse_mode_spec "$spec" || true)
    if [ -z "$parsed" ]; then
        return 1
    fi
    local W H Hz
    read -r W H Hz <<EOF
$parsed
EOF
    local mode_id; mode_id=$(find_mode_id_by_spec "$out_id" "$W" "$H" "$Hz")
    if [ -n "$mode_id" ]; then
        echo "Setting output $out_id to $Wx${H}@${Hz} via mode id $mode_id" >> "$LOGFILE"
        run_kscreen_doctor "kscreen-doctor output.$out_id.mode.$mode_id"
        return 0
    fi
    echo "Could not find mode for $Wx${H}@${Hz} on output $out_id" >> "$LOGFILE"
    return 2
}

log_debug_env_after () {
    echo "==================== DEBUG ENV AFTER START ====================" >> "$LOGFILE"
    echo "DEBUG: Timestamp: $(date)" >> "$LOGFILE"
    echo "DEBUG: kscreen-doctor outputs AFTER:" >> "$LOGFILE"
    kscreen-doctor --json 2>&1 | jq -r '.outputs[] | "id: \(.id) name: \(.name) enabled: \(.enabled) primary: \(.primary)"' >> "$LOGFILE" 2>&1 || echo "kscreen-doctor --json failed in AFTER check" >> "$LOGFILE"
    echo "==================== DEBUG ENV AFTER END ====================" >> "$LOGFILE"
}

enable_all() {
    echo "DISPLAY SWAP: Enabling All" >> "$LOGFILE"
    for out in $(kscreen-doctor --json 2>/dev/null | jq -r '.outputs[].id' 2>/dev/null || echo ""); do
        name=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out" '.outputs[] | select(.id==($id|tonumber)) | .name' 2>/dev/null || echo "unknown")
        echo "Enabling output $out ($name)" >> "$LOGFILE"
        run_kscreen_doctor "kscreen-doctor output.$out.enable"
        sleep 0.5
    done
}

set_physical_primary () {
    virt_name=$(get_virtual_connector_from_cmdline)
    virt_id=$(get_output_id_by_name "$virt_name")
    echo "PHYSICAL_PRIMARY: Virtual connector: $virt_name (id: $virt_id)" >> "$LOGFILE"
    
    # Find first enabled physical output
    for out in $(kscreen-doctor --json 2>/dev/null | jq -r '.outputs[] | .id' 2>/dev/null || echo ""); do
      if [ "$out" != "$virt_id" ]; then
        enabled=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out" '.outputs[] | select(.id==($id|tonumber)) | .enabled' 2>/dev/null || echo "false")
        name=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out" '.outputs[] | select(.id==($id|tonumber)) | .name' 2>/dev/null || echo "unknown")
        echo "PHYSICAL_PRIMARY: Checking output $out ($name), enabled: $enabled" >> "$LOGFILE"
        if [ "$enabled" = "true" ]; then
          echo "PHYSICAL_PRIMARY: Setting physical output $out ($name) as primary" >> "$LOGFILE"
          run_kscreen_doctor "kscreen-doctor output.$out.primary"
          break
        fi
      fi
    done
}

only_virtual () {
    local mode_param="$1"
    echo "==================== ONLY_VIRTUAL START ====================" >> "$LOGFILE"
    echo "ONLY_VIRTUAL: Starting at $(date)" >> "$LOGFILE"
    echo "ONLY_VIRTUAL: Mode parameter: '$mode_param'" >> "$LOGFILE"
    
    virt_name=$(get_virtual_connector_from_cmdline)
    echo "ONLY_VIRTUAL: Virtual connector from cmdline: '$virt_name'" >> "$LOGFILE"
    
    if [ -z "$virt_name" ]; then
        echo "ONLY_VIRTUAL: ERROR - No virtual connector found in cmdline" >> "$LOGFILE"
        return 1
    fi
    
    virt_id=$(get_output_id_by_name "$virt_name")
    echo "ONLY_VIRTUAL: Virtual connector ID: '$virt_id'" >> "$LOGFILE"
    
    if [ -z "$virt_id" ]; then
        echo "ONLY_VIRTUAL: ERROR - Virtual connector '$virt_name' not found in kscreen outputs" >> "$LOGFILE"
        return 1
    fi
    
    # Enable virtual output first
    echo "ONLY_VIRTUAL: Enabling virtual output $virt_id ($virt_name)" >> "$LOGFILE"
    run_kscreen_doctor "kscreen-doctor output.$virt_id.enable"
    run_kscreen_doctor "kscreen-doctor output.$virt_id.primary"
    # Give the compositor a beat to flip primary before disabling others
    sleep 0.5
    
    # Set resolution if mode parameter provided (supports id or WxH@Hz)
    if [ -n "$mode_param" ]; then
        if echo "$mode_param" | grep -Eq '^[0-9]+x[0-9]+@[0-9]+'; then
            echo "ONLY_VIRTUAL: Setting virtual display to $mode_param (by spec)" >> "$LOGFILE"
            set_output_mode_by_spec "$virt_id" "$mode_param" || echo "ONLY_VIRTUAL: Failed to set by spec; will try safe 60Hz fallback" >> "$LOGFILE"
        else
            echo "ONLY_VIRTUAL: Setting virtual display to mode id $mode_param" >> "$LOGFILE"
            run_kscreen_doctor "kscreen-doctor output.$virt_id.mode.$mode_param"
        fi
    else
        # Default to a conservative 60Hz mode on the virtual display
        safe_mode=$(pick_virtual_safe_mode "$virt_id")
        if [ -n "$safe_mode" ]; then
            echo "ONLY_VIRTUAL: Setting virtual display to safe 60Hz mode id $safe_mode" >> "$LOGFILE"
            run_kscreen_doctor "kscreen-doctor output.$virt_id.mode.$safe_mode"
            sleep 0.2
        else
            echo "ONLY_VIRTUAL: No safe 60Hz mode found for virtual display; skipping" >> "$LOGFILE"
        fi
    fi
    
    # Disable all physical outputs (but never end up with all outputs disabled)
    for out in $(kscreen-doctor --json 2>/dev/null | jq -r '.outputs[] | .id' 2>/dev/null || echo ""); do
      if [ "$out" != "$virt_id" ]; then
        name=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out" '.outputs[] | select(.id==($id|tonumber)) | .name' 2>/dev/null || echo "unknown")
        echo "ONLY_VIRTUAL: Disabling physical output $out ($name)" >> "$LOGFILE"
        # Safety: ensure virtual is still enabled before disabling this output
        virt_enabled=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$virt_id" '.outputs[] | select(.id==($id|tonumber)) | .enabled' 2>/dev/null || echo "true")
        if [ "$virt_enabled" = "true" ]; then
            run_kscreen_doctor "kscreen-doctor output.$out.disable"
        else
            echo "ONLY_VIRTUAL: Skipping disable of $out because virtual output is not reported enabled" >> "$LOGFILE"
        fi
      fi
    done
    
    echo "ONLY_VIRTUAL: Completed at $(date)" >> "$LOGFILE"
    echo "==================== ONLY_VIRTUAL END ====================" >> "$LOGFILE"
}

only_physical () {
    echo "==================== ONLY_PHYSICAL START ====================" >> "$LOGFILE"
    echo "ONLY_PHYSICAL: Starting at $(date)" >> "$LOGFILE"
    
    # Ensure at least one physical output is enabled before touching the virtual one
    virt_name=$(get_virtual_connector_from_cmdline)
    echo "ONLY_PHYSICAL: Virtual connector: '$virt_name'" >> "$LOGFILE"
    virt_id=""; [ -n "$virt_name" ] && virt_id=$(get_output_id_by_name "$virt_name")

    # Enable the first physical output (if disabled)
    for out in $(kscreen-doctor --json 2>/dev/null | jq -r '.outputs[].id' 2>/dev/null || echo ""); do
        if [ -n "$virt_id" ] && [ "$out" = "$virt_id" ]; then
            continue
        fi
        enabled=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out" '.outputs[] | select(.id==($id|tonumber)) | .enabled' 2>/dev/null || echo "false")
        name=$(kscreen-doctor --json 2>/dev/null | jq -r --arg id "$out" '.outputs[] | select(.id==($id|tonumber)) | .name' 2>/dev/null || echo "unknown")
        if [ "$enabled" != "true" ]; then
            echo "ONLY_PHYSICAL: Enabling physical display $out ($name)" >> "$LOGFILE"
            run_kscreen_doctor "kscreen-doctor output.$out.enable"
        else
            echo "ONLY_PHYSICAL: Physical display $out ($name) already enabled" >> "$LOGFILE"
        fi
        # Set as primary and stop after first physical
        echo "ONLY_PHYSICAL: Setting physical display $out ($name) as primary" >> "$LOGFILE"
        run_kscreen_doctor "kscreen-doctor output.$out.primary"
        break
    done

    # Small wait before touching the virtual output
    sleep 1

    # Now disable the virtual output if present
    if [ -n "$virt_id" ]; then
        # Before disabling, drop the virtual to a conservative 60Hz mode to reduce link retrain stress
        safe_mode=$(pick_virtual_safe_mode "$virt_id")
        if [ -n "$safe_mode" ]; then
            echo "ONLY_PHYSICAL: Setting virtual display $virt_id ($virt_name) to safe 60Hz mode id $safe_mode before disable" >> "$LOGFILE"
            run_kscreen_doctor "kscreen-doctor output.$virt_id.mode.$safe_mode"
            sleep 0.2
        else
            echo "ONLY_PHYSICAL: No safe 60Hz mode found for virtual display; proceeding to disable" >> "$LOGFILE"
        fi
        echo "ONLY_PHYSICAL: Disabling virtual display $virt_id ($virt_name)" >> "$LOGFILE"
        run_kscreen_doctor "kscreen-doctor output.$virt_id.disable"
    fi

    # Do NOT change DP-1 (or any physical) resolution here
    echo "ONLY_PHYSICAL: Skipping any physical resolution changes by design" >> "$LOGFILE"

    # Avoid DPMS toggles; Wayland/KWin handles this
    echo "ONLY_PHYSICAL: Skipping DPMS refresh by design" >> "$LOGFILE"

    echo "ONLY_PHYSICAL: Completed at $(date)" >> "$LOGFILE"
    echo "==================== ONLY_PHYSICAL END ====================" >> "$LOGFILE"
}

case "$1" in
    --only-virtual ) log_debug_env; only_virtual "$2"; log_debug_env_after;;
    --only-physical ) log_debug_env; only_physical; log_debug_env_after;;
    * ) echo "Usage: $0 [--only-virtual [mode]|--only-physical]" ;;
esac
