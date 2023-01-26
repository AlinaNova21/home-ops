#!/bin/bash
talosctl apply-config -n 192.168.2.2 --file whoverse-rory.yaml
talosctl apply-config -n 192.168.2.3 --file whoverse-amy.yaml
talosctl apply-config -n 192.168.2.6 --file whoverse-river.yaml
