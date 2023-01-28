#!/bin/bash
talhelper genconfig
for YML in ./clusterconfig/*.yaml; do
    IP=$(yq '.machine.network.interfaces[0].addresses[0]' $YML)
    IP=${IP/\/24/}
    echo Applying config $YML to $IP
    talosctl \
        --talosconfig=./clusterconfig/talosconfig \
        apply-config \
        -n $IP \
        --file $YML \
        $@
done
