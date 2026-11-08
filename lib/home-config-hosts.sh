# Shared host table for the scripts that drive every home_config host
# (update-all-hosts, gpg-unlock-all). Sourced, not run; POSIX sh.
#
# THE HOST LIST IS nix/hosts/ in home_config: one host per *.nix there. This
# file only holds what that directory cannot say - the ssh alias where it
# differs from the file name, and how to recognise the machine you are on.
#
# A VPS hostname is whatever the provider assigned, so local identities are a
# table. It mirrors hostMap in nix/hm-switch.nix - add a row to both when a
# host is added.

# hc_hosts <repo>: the nix/hosts/ names, one per line. Fails when there are none.
hc_hosts() {
    [ -d "$1/nix/hosts" ] || return 1
    _hc_found=1
    for _hc_f in "$1"/nix/hosts/*.nix; do
        [ -e "$_hc_f" ] || continue
        basename "$_hc_f" .nix
        _hc_found=0
    done
    return "$_hc_found"
}

# hc_alias <host> <off_lan 0|1>: the ssh alias for a nix/hosts/ name.
hc_alias() {
    case "$1" in
        openta) echo openta-vps ;;
        berlix) if [ "$2" -eq 1 ]; then echo berlix-ts; else echo berlix; fi ;;
        *) echo "$1" ;;
    esac
}

# hc_local_host <user@hostname>: the nix/hosts/ name of that machine, or nothing.
hc_local_host() {
    case "$1" in
        nelson@asterix)        echo asterix ;;
        nelson@berlix)         echo berlix ;;
        nelson@gudrun)         echo gudrun ;;
        nelson@gudrun-wsl)     echo gudrun-wsl ;;
        nloyola@opentaproject) echo openta ;;
        nloyola@ms-ubuntu-1)   echo stellan-vps ;;
        nloyola@srv899874)     echo replica-vps ;;
        tikitak@srv985437)     echo tikitak-vps ;;
    esac
}
