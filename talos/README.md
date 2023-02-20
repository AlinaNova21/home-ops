# TALOS

## Bootstrap

1. `bash init-talos.sh --insecure` to initialize talos
2. In seperate terminal when waiting: `task talos:bootstrap`
3. Done! Cluster should be bootstraped and flux taking over.

## Upgrade

1. Update `TALOS_IMAGE` in `Taskfile.yml`
2. `task talos:upgrade`
