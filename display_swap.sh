#!/bin/bash
LOGFILE="$HOME/.config/userscripts/log.log"
DISPLAY_CFG_PATH="$HOME/.config/nobara-vd"

apply_display_config () {
    FILENAME=$1

    echo "DISPLAY SWAP: Activating config $FILENAME" | tr -d '.' >> "$LOGFILE"

    # Just in case connected displays are asleep, wake them
    kscreen-doctor --dpms on

    cat "$DISPLAY_CFG_PATH/$FILENAME" \
    | sed -e "s/true/enable/g;s/false/disable/g" \
    | sort -t. -rk 2 | awk NF \
    | xargs -I {} kscreen-doctor output.{}

    echo "DISPLAY SWAP: $(kscreen-doctor --json | jq -r '.outputs[] | "\(.id) \(.name) \(.enabled)"' | tr '\n' ' ')" >> "$LOGFILE"
}

enable_all() {
    echo "DISPLAY SWAP: Enabling All" >> "$LOGFILE"
    kscreen-doctor --json | jq -r '.outputs[].id' | xargs -I {} kscreen-doctor output.{}.enable

    echo "DISPLAY SWAP: $(kscreen-doctor --json | jq -r '.outputs[] | "\(.id) \(.name) \(.enabled)"' | tr '\n' ' ')" >> "$LOGFILE"
}

write_display_config () {
    CONFIG_NAME=$1

    mkdir -p "$DISPLAY_CFG_PATH"
    kscreen-doctor --json | jq -r '[.outputs[].modes[] | .["mode"] = .currentModeId | {"id", "enabled", "mode"}]' > "$DISPLAY_CFG_PATH/$CONFIG_NAME"
}


case "$1" in
    --start-stream ) apply_display_config ".display_streaming";;
    --end-stream ) apply_display_config .display_default;;
    --write-default ) write_display_config ".display_default";;
    --write-stream ) write_display_config ".display_streaming";;
    --enable-all ) enable_all;;
    * ) break ;;
esac