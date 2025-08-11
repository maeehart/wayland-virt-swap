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

## Usage
- Switch to virtual-only (DP-2 primary, physical off):

```zsh
./display_swap.sh --only-virtual
```

    - Optional: pass a specific mode id for the virtual output (from `kscreen-doctor --json`). When omitted, a safe 60 Hz mode is chosen automatically.

- Switch back to physical-only (DP-1 primary, virtual off):

```zsh
./display_swap.sh --only-physical
```

Design guarantees:
- Physical resolution is never changed.
- Virtual output is kept to conservative 60 Hz to reduce link/pipeline shocks.
- Safe sequencing avoids disabling all outputs.
- Detailed logs are written to `~/.config/userscripts/log.log`.

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