#!/usr/bin/env bash

DEST=$HOME/.local/share/fonts
VERSION=v3.3.0

mkdir -p "$DEST"

cd /tmp || exit 1
# Only the faces Nix does not already provide. nix/desktop.nix installs
# nerd-fonts.{caskaydia-cove,fira-code,go-mono,hack,jetbrains-mono,noto,
# ubuntu,ubuntu-mono}, so CascadiaCode, FiraCode, Go-Mono, Hack,
# JetBrainsMono and UbuntuMono used to be downloaded here only to duplicate
# the store copies in ~/.local/share/fonts. Before adding a font below, check
# whether nerd-fonts.<name> exists and declare it there instead - a declared
# package beats a hand-installed zip.
fonts=(
    "Inconsolata"
    "Iosevka"
    "Mononoki"
    "RobotoMono"
    "SourceCodePro"
    "UbuntuSans"
)

for font in "${fonts[@]}"
do
    # Download first, and skip the font entirely if that fails. The clear
    # below is destructive, so it must never run against a download that
    # did not arrive - that would delete a working font and install nothing.
    if ! wget "https://github.com/ryanoasis/nerd-fonts/releases/download/$VERSION/$font.zip"
    then
        echo "$font: download failed, leaving the installed copy alone" >&2
        continue
    fi

    # Each release renames its files ("Iosevka Nerd Font Complete Bold.ttf" in
    # v2 is "IosevkaNerdFont-Bold.ttf" in v3), so unzipping on top of an older
    # install adds a second full generation instead of replacing the first.
    # Iosevka reached 2.9 GiB that way: 216 v2 files next to 81 v3 ones. Clear
    # the directory so an install is a replacement, not an accumulation.
    rm -rf "${DEST:?}/${font:?}"

    # -o goes before the archive name. After it, unzip reads "-f" as a
    # file-to-extract pattern, matches nothing, and exits 11 having written
    # nothing at all - which is what the previous "unzip $font.zip -f -d ..."
    # did on every run.
    unzip -o -q "$font.zip" -d "$DEST/$font/"

    rm -f "$font.zip"
done

fc-cache -f
