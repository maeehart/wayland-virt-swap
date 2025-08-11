#!/usr/bin/env bash

# 4k 144hz https://www.displayspecifications.com/en/model/407f14c5
# Grab more from https://git.linuxtv.org/v4l-utils.git/tree/utils/edid-decode/data
# Note that they might not work, Wayland doesn't like messing with certain colour formats
EDID_FILENAME=acer-xv273k-corrected_difdb

OUTPUT_TYPE=DP # DP or HDMI, best to leave as DP for compatibility

# Optional: target a specific DRM card when multiple GPUs are present
# Set via CLI flags: --render-node /dev/dri/renderD128 | --card card0 | --card-index 0
TARGET_CARD=""

print_err() { echo "[nobara-vd] $*" >&2; }

usage() {
    cat <<USAGE
Usage: $0 [--render-node /dev/dri/renderDXXX | --card cardN | --card-index N]
  --render-node   Path to render node for the GPU to target, e.g. /dev/dri/renderD128
  --card          DRM card name, e.g. card0
  --card-index    Numeric index, e.g. 0 (equivalent to card0)
USAGE
}

resolve_card_from_rendernode() {
    local rn="$1"
    if [ ! -e "$rn" ]; then
        print_err "Render node not found: $rn"; return 1
    fi
    # Find the device directory for the render node
    local dev_path
    dev_path=$(readlink -f "/sys/class/drm/$(basename "$rn")/device" 2>/dev/null || true)
    if [ -z "$dev_path" ]; then
        print_err "Unable to resolve sysfs device for $rn"; return 1
    fi
    # Find matching cardX whose 'device' symlink points to the same device
    local c
    for c in /sys/class/drm/card*; do
        [ -d "$c" ] || continue
        local c_dev
        c_dev=$(readlink -f "$c/device" 2>/dev/null || true)
        if [ -n "$c_dev" ] && [ "$c_dev" = "$dev_path" ]; then
            TARGET_CARD=$(basename "$c")
            return 0
        fi
    done
    print_err "Could not map $rn to a DRM card"
    return 1
}

# Parse CLI args
while [ $# -gt 0 ]; do
    case "$1" in
        --render-node)
            shift; RN_PATH="$1"; resolve_card_from_rendernode "$RN_PATH" || exit 1; ;;
        --card)
            shift; TARGET_CARD="$1" ;;
        --card-index)
            shift; TARGET_CARD="card$1" ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            print_err "Unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
done

# Utility functions
# ==================================================================================================

append_to_parameter() {
    INPUT=${1#*=}
    KEY=$2
    VALUE=$3

    PARAMS_NEW="$(echo $INPUT | tr -d "\'"\
    | awk -v insert="$VALUE" -v key="$KEY" '{
        split($0, A, " ");
        for(a in A) 
            if (A[a] ~ "^" key) 
                {split(A[a], B, "="); print B[1]"="B[2]","insert} 
            else 
                {print A[a]}
    }' | tr '\n' ' ' | awk '{$1=$1};1' )" 

    echo "GRUB_CMDLINE_LINUX_DEFAULT='$PARAMS_NEW'"
}

replace_parameter () {
    INPUT=${1#*=}
    KEY=$2
    VALUE=$3

    PARAMS_NEW="$(echo $INPUT | tr -d "\'" \
    | awk -v insert="$VALUE" -v key="$KEY" '{
        split($0, A, " ")
        for(a in A) 
            if (A[a] ~ "^" key) {
                split(A[a], B, "="); print B[1]"="insert} 
            else 
                {print A[a]}
    }' | tr '\n' ' ' | awk '{$1=$1};1' )" 

    echo "GRUB_CMDLINE_LINUX_DEFAULT='$PARAMS_NEW'"
}

new_parameter () {
    INPUT=$1
    KEY=$2
    VALUE=$3
    echo "${INPUT:: -1} $KEY=$VALUE'"
}

add_parameter() {
    INPUT=$1
    KEY=$2
    VALUE=$3
    APPEND=$4

    # Check if already present
    if echo "$INPUT" | grep -q "$KEY"; then
        if [ $APPEND == 'true' ]; then 
            echo $(append_to_parameter "$INPUT" "$KEY" "$VALUE,")
        else
            # If reusing, replace
            echo $(replace_parameter "$INPUT" "$KEY" "$VALUE")
        fi
    else
        # Append parameter
        echo $(new_parameter "$INPUT" "$KEY" "$VALUE")
    fi
}


# Core functions
# ==================================================================================================

clean_up () {
    cd ..
    rm -rf scratchpad
}

init_nobara_vd () {

    # Backup the users default grub, and don't overwrite it
    if [ ! -f ./grub.bak ]; then
        cp /etc/default/grub grub.bak
    fi

    # Detect bootloader and record for later steps
    BOOTLOADER="unknown"
    if [ -f /etc/default/grub ]; then
        BOOTLOADER="grub"
    elif [ -d /boot/loader/entries ]; then
        BOOTLOADER="systemd-boot"
    fi
    echo "Detected bootloader: $BOOTLOADER"
    export BOOTLOADER

    # Check if the user has more than one graphics device enabled
    # Devices are assigned card numbers on boot and they aren't consistent
    NUM_CARDS=$(for p in /sys/class/drm/*/status; do con=${p%/status}; prefix=${con#*/drm\/}; echo "${prefix%%-*} "; done | sort | uniq | wc -l)

    if (( NUM_CARDS > 1 )) && [ -z "$TARGET_CARD" ]; then
        echo "Detected $NUM_CARDS DRM cards."
        echo "Please rerun with one of: --render-node /dev/dri/renderDXXX | --card cardN | --card-index N"
        exit 1
    fi
    if [ -n "$TARGET_CARD" ]; then
        echo "Targeting DRM card: $TARGET_CARD"
        if [ ! -d "/sys/class/drm/$TARGET_CARD" ]; then
            print_err "Target card not found: $TARGET_CARD"; exit 1
        fi
    fi

    mkdir -p scratchpad
    cd scratchpad
}

load_edid_into_firmware () {
    # Create edid directory and copy file
    if [ ! -d /usr/lib/firmware/edid ]; then
        sudo mkdir -p /usr/lib/firmware/edid
    fi

    if [ ! -f /usr/lib/firmware/edid/$EDID_FILENAME ]; then
        # Download edid and move to firmware
        wget "https://git.linuxtv.org/v4l-utils.git/plain/utils/edid-decode/data/$EDID_FILENAME"
        sudo cp $EDID_FILENAME /usr/lib/firmware/edid/
    fi

    # Include EDID in initramfs so it's available to the drivers at boot
    # Prefer dracut if available; otherwise use mkinitcpio (Arch)
    if command -v dracut >/dev/null 2>&1; then
        if command -v lsinitrd >/dev/null 2>&1 && ! sudo lsinitrd | grep -q "usr/lib/firmware/edid/$EDID_FILENAME"; then
            echo "Including EDID via dracut (detected)"
            sudo dracut --include "/usr/lib/firmware/edid/$EDID_FILENAME" "/usr/lib/firmware/edid/$EDID_FILENAME" --force
        else
            echo "EDID already present in initramfs (dracut) or lsinitrd unavailable"
        fi
    elif command -v mkinitcpio >/dev/null 2>&1; then
        echo "Ensuring EDID is included in mkinitcpio image"
        MKCONF=/etc/mkinitcpio.conf
        EDID_PATH="/usr/lib/firmware/edid/$EDID_FILENAME"
        if ! grep -q "^FILES=.*$EDID_PATH" "$MKCONF"; then
            if grep -q "^FILES=" "$MKCONF"; then
                # Prepend EDID inside the existing FILES=( ... )
                sudo sed -i "s|^FILES=(|FILES=($EDID_PATH |" "$MKCONF"
            else
                echo "FILES=($EDID_PATH)" | sudo tee -a "$MKCONF" >/dev/null
            fi
        fi
        echo "Rebuilding initramfs with mkinitcpio (-P)"
        sudo mkinitcpio -P
    else
        echo "Warning: Neither dracut nor mkinitcpio found. Ensure initramfs includes $EDID_FILENAME manually."
    fi
}


choose_display_port () {
    # Find first free port on the targeted card (if specified)
    local pattern
    if [ -n "$TARGET_CARD" ]; then
        pattern="/sys/class/drm/${TARGET_CARD}-*/status"
    else
        pattern="/sys/class/drm/*/status"
    fi
    DISP_OUT=$(for p in $pattern; do con=${p%/status}; echo -n "${con#*/card?-}: "; cat "$p"; done | grep disconnected | grep "$OUTPUT_TYPE" | awk 'NR==1{split($1,A,":"); print A[1]}')

    DISP_TO_BIND=$DISP_OUT


    # Check for previously bound EDIDs in kernel params
    CURRENT_EDID_KERNAL_PARAM=""
    if [ "$BOOTLOADER" = "grub" ] && [ -f /etc/default/grub ]; then
        CURRENT_EDID_KERNAL_PARAM=$(grep -o "drm.edid_firmware=.*:edid" /etc/default/grub | grep -o "=.*:" | tr -d '=' | tr -d ':')
    elif [ "$BOOTLOADER" = "systemd-boot" ] && [ -d /boot/loader/entries ]; then
        DEFAULT_ENTRY=$(grep -E "^default" /boot/loader/loader.conf 2>/dev/null | awk '{print $2}')
        if [ -z "$DEFAULT_ENTRY" ] || [ "$DEFAULT_ENTRY" = "auto" ]; then
            DEFAULT_ENTRY=$(ls -1 /boot/loader/entries/*.conf 2>/dev/null | head -n1)
        else
            DEFAULT_ENTRY="/boot/loader/entries/$DEFAULT_ENTRY"
        fi
        if [ -n "$DEFAULT_ENTRY" ] && [ -f "$DEFAULT_ENTRY" ]; then
            CURRENT_EDID_KERNAL_PARAM=$(grep -E "^options " "$DEFAULT_ENTRY" | grep -o "drm.edid_firmware=[^ ]*" | sed -E 's/.*=([^:]*):.*/\1/')
        fi
    fi


    # If user already has an edid param, ask if they want to reuse that port or use another free one
    # TODO, validate there are free ports first XD
    # Probably just check which are actually connected? Grub config doesn't necessarily reflect current system state
    if [ -n "$CURRENT_EDID_KERNAL_PARAM" ]; then 
        echo "You currently have an EDID bound to : $CURRENT_EDID_KERNAL_PARAM"
        PS3="Please enter your choice: "
        options=("Reuse $CURRENT_EDID_KERNAL_PARAM" "Use disconnected $DISP_OUT" "Quit")
        select opt in "${options[@]}"
        do
            case $opt in
                "Reuse $CURRENT_EDID_KERNAL_PARAM")
                    DISP_TO_BIND=$CURRENT_EDID_KERNAL_PARAM
                    break
                    ;;
                "Use disconnected $DISP_OUT")
                    DISP_TO_BIND=$DISP_OUT
                    break
                    ;;
                "Quit")
                    return 0 ;;
                *) echo "invalid option $REPLY";;
            esac
        done
        clear
    fi
}


configure_kernel_params() {
    # Common values
    DRM_FIRMWARE=$DISP_TO_BIND:edid/$EDID_FILENAME

    # Set default video to user choice
    PS3="Select default mode: "
    select mode in "3840x2160 120Hz" "2560x1440 120Hz" "1920x1080 120Hz" exit; do 
    case $mode in
        exit) echo "exiting"; return 0;;
            *)  SELECTED_MODE=$(echo $mode | tr ' ' '@' |  sed 's/Hz//g;s/$/e/'); break;;
    esac
    done

    DEFAULT_VIDEO="$DISP_TO_BIND:$SELECTED_MODE"

    if [ "$BOOTLOADER" = "grub" ]; then
        # Read current value inside quotes and rebuild safely with double quotes
        CURRENT_VAL=$(awk -F'"' '/^GRUB_CMDLINE_LINUX_DEFAULT=/ {print $2}' /etc/default/grub)
        # Remove any existing drm.edid_firmware= and video= tokens
        FILTERED=$(printf '%s\n' "$CURRENT_VAL" | awk -v RS=' ' -v ORS=' ' '!/^drm.edid_firmware=|^video=/ {print}' | sed 's/[[:space:]]*$//')
        NEW_VAL="$FILTERED drm.edid_firmware=$DRM_FIRMWARE video=$DEFAULT_VIDEO"
        # Normalize whitespace
        NEW_VAL=$(printf '%s\n' "$NEW_VAL" | awk '{$1=$1;print}')
        # Replace the line in the file content
        GRUB_TO_WRITE=$(awk -v newval="$NEW_VAL" 'BEGIN{q="\""} /^GRUB_CMDLINE_LINUX_DEFAULT=/ { print "GRUB_CMDLINE_LINUX_DEFAULT=" q newval q; next } { print }' /etc/default/grub)
        export GRUB_TO_WRITE
    elif [ "$BOOTLOADER" = "systemd-boot" ]; then
        DEFAULT_ENTRY=$(grep -E "^default" /boot/loader/loader.conf 2>/dev/null | awk '{print $2}')
        if [ -z "$DEFAULT_ENTRY" ] || [ "$DEFAULT_ENTRY" = "auto" ]; then
            DEFAULT_ENTRY=$(ls -1 /boot/loader/entries/*.conf 2>/dev/null | head -n1)
        else
            DEFAULT_ENTRY="/boot/loader/entries/$DEFAULT_ENTRY"
        fi
        if [ -z "$DEFAULT_ENTRY" ] || [ ! -f "$DEFAULT_ENTRY" ]; then
            echo "Error: systemd-boot entry not found; please adjust manually."
            return 1
        fi
        ENTRY_FILE="$DEFAULT_ENTRY"
        OPTIONS_LINE=$(grep -E "^options " "$ENTRY_FILE" || echo "options")
        OPTIONS_LINE_NEW=$(echo "$OPTIONS_LINE" | awk -v k1="drm.edid_firmware" -v v1="$DRM_FIRMWARE" -v k2="video" -v v2="$DEFAULT_VIDEO" '{
            # Replace if exists
            for (i=1;i<=NF;i++) {
                if ($i ~ /^drm.edid_firmware=/) { $i=k1"="v1 }
                if ($i ~ /^video=/) { $i=k2"="v2 }
            }
            out=$0
            if (out !~ /drm.edid_firmware=/) out=out" "k1"="v1
            if (out !~ /video=/) out=out" "k2"="v2
            print out
        }')
        export ENTRY_FILE OPTIONS_LINE_NEW
    else
        echo "Error: Unsupported or unknown bootloader."
        return 1
    fi
}


write_grub_config_and_update () {
    if [ "$BOOTLOADER" = "grub" ]; then
        echo "Grub file to write is: "
        echo "$GRUB_TO_WRITE"
        echo ''
        read -p "Apply changes and regenerate grub.cfg? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$GRUB_TO_WRITE" | sudo tee /etc/default/grub > /dev/null
            if command -v update-grub >/dev/null 2>&1; then
                sudo update-grub
            else
                # Arch/vanilla GRUB
                if [ -d /boot/grub ]; then
                    sudo grub-mkconfig -o /boot/grub/grub.cfg
                else
                    echo "Warning: /boot/grub not found; please regenerate GRUB config manually."
                fi
            fi
        fi
    elif [ "$BOOTLOADER" = "systemd-boot" ]; then
        echo "Updating systemd-boot entry: $ENTRY_FILE"
        echo "$OPTIONS_LINE_NEW"
        read -p "Apply changes to $ENTRY_FILE? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if grep -qE "^options " "$ENTRY_FILE"; then
                sudo sed -i "s|^options .*$|$OPTIONS_LINE_NEW|" "$ENTRY_FILE"
            else
                echo "$OPTIONS_LINE_NEW" | sudo tee -a "$ENTRY_FILE" >/dev/null
            fi
            echo "systemd-boot updated."
        fi
    else
        echo "No supported bootloader detected; please update kernel parameters manually."
    fi
}



run () {
    init_nobara_vd

    load_edid_into_firmware

    choose_display_port

    configure_kernel_params

    write_grub_config_and_update

    clean_up
}

run
