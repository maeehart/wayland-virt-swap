#!/bin/bash
start_stream() {
    cat "$(getent passwd "$USER" | cut -d: -f6)/.config/nobara-vd/.monitor_streaming" \
    | sed -e "s/true/enable/g;s/false/disable/g" \
    | sort -t. -rk 2 | awk NF \
    | xargs -I {} kscreen-doctor output.{}
}

end_stream() {
    cat "$(getent passwd "$USER" | cut -d: -f6)/.config/nobara-vd/.monitor_default" \
    | sed -e "s/true/enable/g;s/false/disable/g" \
    | sort -t. -rk 2 | awk NF \
    | xargs -I {} kscreen-doctor output.{}
}

enable_all() {
    kscreen-doctor --json | jq -r '.outputs[].id' | xargs -I {} kscreen-doctor output.{}.enable
}

write_default_monitors () {
    mkdir -p "$(getent passwd "$USER" | cut -d: -f6)/.config/nobara-vd"
    kscreen-doctor --json | jq -r '.outputs[] | "\(.id).\(.enabled)"' > "$(getent passwd "$USER" | cut -d: -f6)/.config/nobara-vd/.monitor_default"
}

write_streaming_monitors () {
    mkdir -p "$(getent passwd "$USER" | cut -d: -f6)/.config/nobara-vd"
    kscreen-doctor --json | jq -r '.outputs[] | "\(.id).\(.enabled)"' > "$(getent passwd "$USER" | cut -d: -f6)/.config/nobara-vd/.monitor_streaming"
}


case "$1" in
    --start-stream ) start_stream;;
    --end-stream ) end_stream;;
    --write-default ) write_default_monitors;;
    --write-stream ) write_streaming_monitors;;
    --enable-all ) enable_all;;
    * ) break ;;
esac