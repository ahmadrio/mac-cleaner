#!/bin/bash
# SUDO_ASKPASS helper: asks for the admin password in a native dialog (used by the engine).
osascript -e 'on run argv' -e 'display dialog (item 1 of argv) default answer "" with hidden answer with title "Mac Cleaner" with icon caution' -e 'text returned of result' -e 'end run' "${1:-Password:}" || exit 1
