#!/bin/bash
talhelper genconfig
pushd clusterconfig
talosctl apply-config -n 192.168.2.2 --file whoverse-rory.cluster.whoverse.dev.yaml
talosctl apply-config -n 192.168.2.3 --file whoverse-amy.cluster.whoverse.dev.yaml
talosctl apply-config -n 192.168.2.6 --file whoverse-river.cluster.whoverse.dev.yaml
