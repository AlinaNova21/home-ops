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
while ! kubectl get nodes 2>/dev/null 1>/dev/null; do echo Waiting on api; sleep 10; done
kubectl kustomize --enable-helm ../kubernetes/bootstrap | kubectl apply -f -
cat ~/.config/sops/age/keys.txt | kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin
sops --decrypt ../kubernetes/flux/vars/cluster-secrets.sops.yaml | kubectl apply -f -
kubectl apply -f ../kubernetes/flux/vars/cluster-settings.yaml
kubectl apply --kustomize ../kubernetes/flux/config
