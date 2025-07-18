#!/bin/bash

# 4k 144hz https://www.displayspecifications.com/en/model/407f14c5
# Grab more from https://git.linuxtv.org/v4l-utils.git/tree/utils/edid-decode/data
# Note that they might not work, Wayland doesn't like messing with certain colour formats
EDID_FILENAME=acer-xv273k-corrected_difdb

OUTPUT_TYPE=DP # DP or HDMI, best to leave as DP for compatibility

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

    # Check if the user has more than one graphics device enabled
    # Devices are assigned card numbers on boot and they aren't consistent
    NUM_CARDS=$(for p in /sys/class/drm/*/status; do con=${p%/status}; prefix=${con#*/drm\/}; echo "${prefix%%-*} "; done | sort | uniq | wc -l)

    if (( $NUM_CARDS > 1 )); then
        echo "Error: Please disable integrated graphics in bios or remove extra graphics card."
        echo "Cards are not uniquely assigned and so the configured virtual display may end up rendering on the wrong graphics device."
        exit 1
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

    # Include edid in initramfs so it's available to the drivers at boot 
    # https://wiki.archlinux.org/title/Kernel_mode_setting#Early_KMS_start

    if ! sudo lsinitrd | grep -q "usr/lib/firmware/edid/$EDID_FILENAME"; then
        echo "Including edid firmware in initramfs, please wait.."
        sudo dracut --include "/usr/lib/firmware/edid/$EDID_FILENAME" "/usr/lib/firmware/edid/$EDID_FILENAME" --force
    else 
        echo "Firmware already present in initramfs"
    fi
}


choose_display_port () {
    # Find first free port
    DISP_OUT=$(for p in /sys/class/drm/*/status; do con=${p%/status}; echo -n "${con#*/card?-}: "; cat $p; done | grep disconnected | grep "$OUTPUT_TYPE" | awk 'NR==1{split($1,A,":"); print A[1]}')

    DISP_TO_BIND=$DISP_OUT


    # Check for previously bound edids in kernal params
    CURRENT_EDID_KERNAL_PARAM=$(cat /etc/default/grub | grep -o "drm.edid_firmware=.*:edid" | grep -o "=.*:" | tr -d '=' | tr -d ':')


    # If user already has an edid param, ask if they want to reuse that port or use another free one
    # TODO, validate there are free ports first XD
    # Probably just check which are actually connected? Grub config doesn't necessarily reflect current system state
    if ! [ -z ${CURRENT_EDID_KERNAL_PARAM} ]; then 
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
                    return 0
                   for p in /sys/class/drm/*/status; do con=${p%/status}; echo -n "${con#*/card?-}: "; cat $p; done ;;
                *) echo "invalid option $REPLY";;
            esac
        done
        clear
    fi
}


configure_kernel_params() {
    GRUB_DEFAULT=$(cat /etc/default/grub | grep GRUB_CMDLINE_LINUX_DEFAULT)

    # Set edid_firmware
    DRM_FIRMWARE=$DISP_TO_BIND:edid/$EDID_FILENAME

    APPEND=$( [ "$DISP_TO_BIND" = "$CURRENT_EDID_KERNAL_PARAM" ] && echo 'false' || echo 'true' )
    
    GRUB_DEFAULT_NEW="$(add_parameter "$GRUB_DEFAULT" 'drm.edid_firmware' "$DRM_FIRMWARE" "$APPEND")"

    # Set default video to user choice
    PS3="Select default mode: "
    select mode in "3840x2160 120Hz" "2560x1440 120Hz" "1920x1080 120Hz" exit; do 
    case $mode in
        exit) echo "exiting"
                return 0;;
            *)  SELECTED_MODE=$(echo $mode | tr ' ' '@' |  sed 's/Hz//g;s/$/e/'); break;;
    esac
    done

    DEFAULT_VIDEO="$DISP_TO_BIND:$SELECTED_MODE"

    GRUB_DEFAULT_NEW="$(add_parameter "$GRUB_DEFAULT_NEW" 'video' "$DEFAULT_VIDEO" "$APPEND")"


    GRUB_TO_WRITE=$(cat /etc/default/grub | awk -v var="$GRUB_DEFAULT_NEW" '/GRUB_CMDLINE_LINUX_DEFAULT/ { print var; next } 1')
}


write_grub_config_and_update () {
    echo "Grub file to write is: "
    echo "$GRUB_TO_WRITE"
    echo ''

    read -p "Are you sure? (y/n) " -n 1 -r

    if [[ $REPLY =~ ^[Yy]$ ]];
    then
        echo "$GRUB_TO_WRITE" | sudo tee /etc/default/grub > /dev/null

        sudo update-grub
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
