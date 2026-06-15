#!/usr/bin/env bash

######################################################################
# Runner-side orchestration: seed caches into the VM, copy this repo in,
# run the in-VM build pipeline, then copy the built debs back out.
######################################################################

set -euo pipefail

# shellcheck disable=SC1091
source /tmp/vm-info.sh

echo "Waiting for cloud-init to finish..."
ssh debian@"$VM_IP" "cloud-init status --wait" || true
ssh debian@"$VM_IP" "sudo apt-get update -qq && sudo apt-get install -y -qq rsync git ca-certificates"

# Seed cached dependency debs into the VM (cache restored on the runner by the
# workflow's actions/cache steps). vm-build.sh skips a build when its deb dir
# is already populated.
seed_cache () {  # $1 = host dir, $2 = VM dir
  if [ -d "$1" ] && compgen -G "$1/*.deb" >/dev/null 2>&1; then
    echo "Seeding $2 in VM from cache ($1)"
    ssh debian@"$VM_IP" "mkdir -p $2"
    rsync -az "$1"/ debian@"$VM_IP":"$2"/
  fi
}
seed_cache /tmp/zfs-debs   /tmp/zfs-debs
seed_cache /tmp/samba-debs /tmp/samba-debs

echo "Copying SSSD packaging repo into the VM..."
ssh debian@"$VM_IP" "mkdir -p ~/sssd"
rsync -az --exclude='.git' "$GITHUB_WORKSPACE"/ debian@"$VM_IP":~/sssd/

echo "Running in-VM build (zfs -> samba -> sssd)..."
ssh debian@"$VM_IP" \
  "ZFS_REPO='${ZFS_REPO}' ZFS_BRANCH='${ZFS_BRANCH}' SAMBA_REPO='${SAMBA_REPO}' SAMBA_BRANCH='${SAMBA_BRANCH}' \
   bash ~/sssd/.github/workflows/scripts/vm-build.sh"

echo "Copying built debs back to the runner (for caching + artifact upload)..."
mkdir -p /tmp/zfs-debs /tmp/samba-debs /tmp/out
rsync -az debian@"$VM_IP":/tmp/zfs-debs/   /tmp/zfs-debs/   || true
rsync -az debian@"$VM_IP":/tmp/samba-debs/ /tmp/samba-debs/ || true
rsync -az debian@"$VM_IP":/tmp/out/        /tmp/out/        || true

echo "Built SSSD packages:"
ls -la /tmp/out || true
