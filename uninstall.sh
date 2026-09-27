#!/bin/sh
# Uninstalls the mod; see README.md. Usage: sh uninstall.sh [options]
exec sh "$(dirname "$0")/installer/kakt_mod.sh" uninstall "$@"
