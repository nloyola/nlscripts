#!/bin/bash

usage() { echo "Usage: $0 [-s SOCKET_NAME] FILE1 .. FILEn" 1>&2; exit 1; }

OPTS="-n -c"
SOCKET=""

while getopts ":s" o; do
    case "${o}" in
        s)
            SOCKET="${OPTARGS}"
            ;;
        *)
            usage
            ;;
    esac
done

if [ ! -z "$SOCKET"]; then
   OPTS="$OPTS --socket-name=$SOCKET -c"
fi

if [ -f $HOME/installs/bin/emacs ]; then
    EMACS_PATH=$HOME/installs/bin
fi

if [ -f $HOME/bin/bin/emacs ]; then
    EMACS_PATH=$HOME/bin/bin
fi

if [ -f /usr/bin/emacs ]; then
    EMACS_PATH=/usr/bin
fi

if [ -f /usr/local/bin/emacs ]; then
    EMACS_PATH=/usr/local/bin
fi

if [ "$EMACS_PATH" == "" ]; then
    echo "No path to Emacs"
    exit
fi

OPTS="$OPTS -a $EMACS_PATH/emacs"

$EMACS_PATH/emacsclient $OPTS $* &
