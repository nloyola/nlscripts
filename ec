#!/usr/bin/env bash
#
# ec - open files in the running Emacs (via emacsclient), reusing the
# existing frame. Falls back to starting a standalone Emacs if no server
# is reachable.

set -euo pipefail

usage() { echo "Usage: ${0##*/} [-s SOCKET_NAME] FILE1 .. FILEn" 1>&2; exit 1; }

socket=""
while getopts ":s:" o; do
    case "$o" in
        s) socket="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

emacsclient=$(command -v emacsclient) || { echo "emacsclient not found in PATH" 1>&2; exit 1; }
emacs=$(command -v emacs)             || { echo "emacs not found in PATH" 1>&2; exit 1; }

opts=(--no-wait --alternate-editor="$emacs")
[ -n "$socket" ] && opts+=(--socket-name="$socket")

exec "$emacsclient" "${opts[@]}" "$@"
