#!/bin/bash

set -x

for f in 20*; do
    d="${f:0:8}"
    if [[ ! -d "$d" ]]; then
        mkdir "$d"
    fi
    if [[ -f "$f" ]]; then
        mv "$f" "$d"
    fi
done
