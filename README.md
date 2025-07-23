# nobara-vd
Create virtual displays automatically on KDE Wayland for sunshine streaming.

## Current Features:
- Download edid file, set kernel parameters and add to initramfs
- Define streaming and default display configurations
- Handle display switching for stream start and end

## Planned Features:
- Prevent "no display connected" issue caused by dpms
    - Currently working, waiting for refactor to check in
- Auto-login and lock pc to enable sunshine on boot
    - Currently working, waiting for refactor to check in
- Enable virtual display on logout to prevent "no display connected" issue
    - Currently working, waiting for refactor to check in
- Automate changing host resolution to match client
- Propper logging


### Disclaimer:

While this is currently in a semi-functional state, it's tuned entirely for my personal machine so I can't promise any results. If there are usage instructions in this readme, then this is no longer the case. This repo will probably be renamed at some point in the future. Virtually everything in here can be found with just a little google-fu, it's nothing special. 