#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

set -euo pipefail

# Load dracut library. Using getargbool() from dracut-lib.
load_dracut_libs() {
    # dracut is not friendly to set -eu
    set +euo pipefail
    type getargbool &>/dev/null || . /lib/dracut-lib.sh
    set -euo pipefail
}

dracut_func() {
    # dracut is not friendly to set -eu
    set +euo pipefail
    "$@"; rc=$?
    set -euo pipefail
    return $rc
}

selinux_relabel() {
    # If we have access to coreos-relabel then let's use that because
    # it allows us to set labels on things before switching root
    # If not, fallback to tmpfiles.
    if command -v coreos-relabel; then
        coreos-relabel $1
    else
        echo "Z $1 - - -" >> "/run/tmpfiles.d/$(basename $0)-relabel.conf"
    fi
}

# Propagate initramfs networking if desired. The policy here is:
#
#    - If a networking configuration was provided before this point
#      (most likely via Ignition) and exists in the real root then
#      we do nothing and don't propagate any initramfs networking.
#    - If a user did not provide any networking configuration
#      then we'll propagate the initramfs networking configuration
#      into the real root.
#
# See https://github.com/coreos/fedora-coreos-tracker/issues/394#issuecomment-599721173
propagate_initramfs_networking() {
    # Check the two locations where a user could have provided network configuration
    # On FCOS we only support keyfiles, but on RHCOS we support keyfiles and ifcfg
    if [ -n "$(ls -A /sysroot/etc/NetworkManager/system-connections/)" -o \
         -n "$(ls -A /sysroot/etc/sysconfig/network-scripts/)" ]; then
        echo "info: networking config is defined in the real root"
        echo "info: will not attempt to propagate initramfs networking"
    else
        echo "info: no networking config is defined in the real root"
        if [ -n "$(ls -A /run/NetworkManager/system-connections/)" ]; then
            echo "info: propagating initramfs networking config to the real root"
            cp /run/NetworkManager/system-connections/* /sysroot/etc/NetworkManager/system-connections/
            selinux_relabel /etc/NetworkManager/system-connections/
        else
            echo "info: no initramfs networking information to propagate"
        fi
    fi
}

down_interface() {
    echo "info: taking down network device: $1"
    # On recommendation from the NM team let's try to delete the device
    # first and if that doesn't work then set it to down and flush any
    # associated addresses. Deleting virtual devices (bonds, teams, bridges,
    # ip-tunnels, etc) will clean up any associated kernel resources. A real
    # device can't be deleted so that will fail and we'll fallback to setting
    # it down and flushing addresses.
    if ! ip link delete $1; then
        ip link set $1 down
        ip addr flush dev $1
    fi
}

# Iterate through the interfaces in the machine and take them down.
# Note that in the futre we would like to possibly use `nmcli` networking off`
# for this. See the following two comments for details:
# https://github.com/coreos/fedora-coreos-tracker/issues/394#issuecomment-599721763
# https://github.com/coreos/fedora-coreos-tracker/issues/394#issuecomment-599746049
down_interfaces() {
    if ! [ -z "$(ls /sys/class/net)" ]; then
        for f in /sys/class/net/*; do
            interface=$(basename "$f")
            # The `bonding_masters` entry is not a true interface and thus
            # cannot be taken down. Also skip local loopback
            case "$interface" in
                "lo" | "bonding_masters")
                    continue
                    ;;
            esac
            down_interface $interface
        done
    fi
}

main() {
    # Load libraries from dracut
    load_dracut_libs

    # Take down all interfaces set up in the initramfs
    down_interfaces

    # Clean up all routing
    echo "info: flushing all routing"
    ip route flush table main
    ip route flush cache

    # Hopefully our logic is sound enough that this is never needed, but
    # user's can explicitly disable initramfs network/hostname propagation
    # with the coreos.no_persist_ip karg.
    if dracut_func getargbool 0 'coreos.no_persist_ip'; then
        echo "info: coreos.no_persist_ip karg detected"
        echo "info: skipping propagating initramfs settings"
    else
        propagate_initramfs_networking
    fi

    # Now that the configuration has been propagated (or not)
    # clean it up so that no information from outside of the
    # real root is passed on to NetworkManager in the real root
    rm -rf /run/NetworkManager/
}

main
