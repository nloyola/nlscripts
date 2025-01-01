#!/bin/bash

DEST=$HOME/.local/share/fonts
mkdir -p $DEST

cd /tmp
fonts=(
    "CascadiaCode"
    "FiraCode"
    "Go-Mono"
    "Hack"
    "Inconsolata"
    "Iosevka"
    "JetBrainsMono"
    "Mononoki"
    "RobotoMono"
    "SourceCodePro"
    "UbuntuMono"
    "UbuntuSans"
)

for font in ${fonts[@]}
do
    wget https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/$font.zip
    unzip $font.zip -f -d $DEST/$font/
    rm $font.zip
done

fc-cache
