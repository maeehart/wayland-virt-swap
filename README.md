# Virtual Display Swap for KDE Wayland (fork of nobara-vd)

Create a virtual display on KDE Wayland and safely switch between the virtual and the physical display. Designed to stream only the virtual screen with Sunshine, without touching your physical monitor’s resolution.

This fork targets KDE Wayland on Arch Linux with zsh, but works on Fedora/Ubuntu as well. It supports both GRUB and systemd-boot and uses kscreen-doctor for output control.

## What’s included
- create_vd.sh: Sets up a virtual display by loading a known-good EDID and binding it to a disconnected DP/HDMI connector at boot.
    - Adds the EDID to initramfs (dracut or mkinitcpio) for early availability.
    - Updates your bootloader with drm.edid_firmware and a default video=<connector>:<WxH>@<Hz>e.
    - Can target a specific GPU when multiple are present.
- display_swap.sh: Robust swapper with safety guards.
    - --only-virtual: enables the virtual output, sets it primary, defaults it to a safe 60 Hz mode, and disables physical outputs.
    - --only-physical: enables a physical output, sets it primary, drops the virtual to a safe 60 Hz, then disables it.
    - Never changes your physical display (DP-1) resolution.
    - Avoids all-off conditions and DPMS flapping.
    - Accepts mode selection by WxH@Hz (preferred) or legacy mode id; resolves IDs dynamically from kscreen-doctor JSON.
    - Always targets outputs by connector names (e.g., DP-1, DP-2), not by numeric indices.

## Requirements
- KDE Wayland session
- zsh (scripts are POSIX-sh friendly)
- Packages: jq, kscreen-doctor (KDE), wget
- Ideally a single visible DRM GPU (or explicitly target one via create_vd.sh)

## Setup (GRUB or systemd-boot)
1) Review defaults in create_vd.sh
     - EDID_FILENAME defaults to an Acer XV273K profile.
     - OUTPUT_TYPE defaults to DP.

2) Run the setup script:

```zsh
chmod +x create_vd.sh display_swap.sh
./create_vd.sh
```

It will:
- Download the EDID to /usr/lib/firmware/edid/
- Add it to initramfs (dracut or mkinitcpio)
- Help you bind it to a disconnected connector (e.g., DP-2) and set a default mode
- Update GRUB or systemd-boot with:
    - drm.edid_firmware=<CONNECTOR>:edid/<EDID_FILENAME>
    - video=<CONNECTOR>:<WxH>@<Hz>e

3) Reboot to apply kernel parameters and initramfs changes.

## Configuration (connector names, not indices)
Numeric output indices (like output.1) and mode ids are not stable across boots. This tool uses DRM connector names (e.g., DP-1 for the physical monitor, DP-2 for the virtual one).

You can configure connector names in a simple shell config file. Search order (first wins):
- $XDG_CONFIG_HOME/userscripts/display_swap.conf
- ~/.config/userscripts/display_swap.conf
- ./display_swap.conf (next to the script)

Example config (see display_swap.conf in this repo):

```sh
# Physical/real monitor connector name
PHYSICAL_CONNECTOR_NAME=DP-1

# Virtual connector name
# If omitted, the script tries to read it from the kernel cmdline (drm.edid_firmware=...)
# and falls back to DP-2.
VIRTUAL_CONNECTOR_NAME=DP-2
```

Tip: Verify the names in your session with:

```zsh
kscreen-doctor --json | jq -r '.outputs[] | {id, name, enabled, primary}'
```

## Usage
- Switch to virtual-only (DP-2 primary, physical off):

```zsh
./display_swap.sh --only-virtual
```

- Optional mode selection for the virtual output:
    - Pass a mode by resolution and refresh: WxH@Hz (preferred because mode IDs can change between boots)

```zsh
# Examples (preferred):
./display_swap.sh --only-virtual 1920x1080@60
./display_swap.sh --only-virtual 2560x1440@60
./display_swap.sh --only-virtual 3840x2160@60
```

    - Or pass a legacy mode id (from `kscreen-doctor --json`):

```zsh
# Example (legacy):
./display_swap.sh --only-virtual 5
```

    - When no mode is provided, a safe 60 Hz mode is chosen automatically.

- Switch back to physical-only (DP-1 primary, virtual off):

```zsh
./display_swap.sh --only-physical
```

Design guarantees:
- Physical resolution is never changed.
- Virtual output is kept to conservative 60 Hz to reduce link/pipeline shocks.
- Safe sequencing avoids disabling all outputs.
- Detailed logs are written to `~/.config/userscripts/log.log`.

Tip: To see available modes for the virtual connector, inspect JSON and search for its name (e.g., DP-2):

```zsh
kscreen-doctor --json | jq '.outputs[] | select(.name=="DP-2") | .modes[] | {id, name, size, refreshRate}'
```

## Sunshine integration
- Configure Sunshine to stream the virtual display (the connector name, e.g., DP-2).
- Use hooks to swap displays around your session:

```text
prep do:   /full/path/display_swap.sh --only-virtual
prep undo: /full/path/display_swap.sh --only-physical
output:    DP-2   # your virtual connector name
```

Ensure Sunshine runs in the same KDE Wayland user session.

## Multi-GPU (optional)
If you have multiple GPUs, target the one you want:

```zsh
# Recommended: render node
./create_vd.sh --render-node /dev/dri/renderD128

# Or by DRM card name/index
./create_vd.sh --card card1
./create_vd.sh --card-index 1
```

## Troubleshooting
- If you see artifacts when coming back to physical, ensure DP-1’s resolution is unchanged in the script (it is by default).
- Check logs:
    - System/user: `journalctl -b` and `journalctl --user -b`
    - KWin crashes: `coredumpctl list kwin_wayland` then `coredumpctl info kwin_wayland`
- You can increase the waits in display_swap.sh slightly if your compositor/GPU needs more time.


## Disclaimer
Environment-specific caveats apply. Tested on KDE Wayland with a single dGPU.