#!/bin/sh
# Canonical install. Same as Scripts/install-app.sh / Scripts/auralis.sh install
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/Scripts/install-app.sh" "$@"
