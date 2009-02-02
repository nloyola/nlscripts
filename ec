#!/bin/bash

if [ -f $HOME/apps/bin/emacs ]; then
    EMACS_PATH=$HOME/apps/bin
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
 
$EMACS_PATH/emacsclient -a $EMACS_PATH/emacs -n $* &

