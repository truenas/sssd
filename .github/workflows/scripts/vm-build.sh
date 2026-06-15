#!/usr/bin/env bash

######################################################################
# In-VM build pipeline (runs on the Debian Trixie VM).
#
#   1. truenas/zfs   -> openzfs userspace + -dev debs.
#                       Provides: libzfs7, libzfs7-devel, libnvpair3, libuutil3
#                       (these satisfy Samba's zfs build-deps).
#   2. truenas/samba -> truenas-samba deb. (samba build-depends on zfs, hence
#                       step 1.) Installed before the sssd build because sssd
#                       MUST link the ldb/talloc/tevent/tdb that truenas-samba
#                       ships -- never the stock Debian copies. truenas-samba
#                       Provides (and Conflicts) those.
#   3. truenas-sssd  -> this repo. Build-deps are installed the same way the
#                       TrueNAS build does (no apt pinning): truenas-samba's
#                       Conflicts on the Debian ldb/talloc/tevent/tdb runtime
#                       libs force apt to satisfy sssd's libldb-dev/etc. from
#                       truenas-samba's Provides. Built via ./fetch.sh +
#                       dpkg-buildpackage. A read-only assertion fails the run
#                       if any Debian samba-stack lib got pulled in.
#
# A populated /tmp/{zfs,samba}-debs (seeded from the runner cache) skips the
# corresponding build.
######################################################################

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${ZFS_REPO:=https://github.com/truenas/zfs.git}"
: "${ZFS_BRANCH:=truenas/zfs-2.4-release}"
: "${SAMBA_REPO:=https://github.com/truenas/samba.git}"
: "${SAMBA_BRANCH:=SCALE-v4-23-stable}"

NPROC="$(nproc)"

echo "::group::apt bootstrap"
sudo apt-get update
sudo apt-get install -y build-essential devscripts equivs fakeroot git ca-certificates rsync
echo "::endgroup::"

# NOTE: If a TrueNAS-specific build-dep is missing from vanilla Debian Trixie
# (e.g. Samba's python3-etcd for --enable-etcd-reclock), add the TrueNAS apt
# repo here before the mk-build-deps calls below, e.g.:
#   echo "deb [trusted=yes] <truenas-apt-repo-url> trixie main" \
#     | sudo tee /etc/apt/sources.list.d/truenas.list
#   sudo apt-get update

############################################################
# 1) OpenZFS  (truenas/zfs)
############################################################
echo "::group::OpenZFS ($ZFS_BRANCH)"
if ls /tmp/zfs-debs/*.deb >/dev/null 2>&1; then
  echo "Using cached OpenZFS debs from /tmp/zfs-debs"
else
  sudo apt-get install -y \
    autoconf automake libtool gawk alien dkms po-debconf lsb-release \
    debhelper dh-python \
    libaio-dev libblkid-dev libcurl4-openssl-dev libelf-dev libpam0g-dev \
    libssl-dev libtirpc-dev libudev-dev uuid-dev zlib1g-dev \
    python3-all-dev python3-cffi python3-setuptools python3-sphinx \
    "linux-headers-$(uname -r)"

  rm -rf /tmp/zfsbuild && mkdir -p /tmp/zfsbuild
  git clone --depth 1 --branch "$ZFS_BRANCH" "$ZFS_REPO" /tmp/zfsbuild/zfs
  cd /tmp/zfsbuild/zfs
  ./autogen.sh
  ./configure --prefix=/usr --enable-pyzfs --enable-debuginfo
  # Userspace packages only: the kernel module is not needed to *compile*
  # the downstream userspace packages (samba, sssd). native-deb debs land in
  # the parent of the source tree.
  make -j"$NPROC" native-deb-utils

  mkdir -p /tmp/zfs-debs
  find /tmp/zfsbuild -maxdepth 1 -name '*.deb' ! -name '*dkms*' ! -name '*dracut*' \
    -exec cp -t /tmp/zfs-debs/ {} +
fi
# Install only the libraries + headers (skip zfsutils/zed/initramfs/test).
sudo apt-get install -y /tmp/zfs-debs/openzfs-lib*.deb
echo "::endgroup::"

############################################################
# 2) TrueNAS Samba  (truenas/samba)
############################################################
echo "::group::TrueNAS Samba ($SAMBA_BRANCH)"
if ls /tmp/samba-debs/*.deb >/dev/null 2>&1; then
  echo "Using cached TrueNAS Samba debs from /tmp/samba-debs"
else
  rm -rf /tmp/sambabuild && mkdir -p /tmp/sambabuild
  git clone --depth 1 --branch "$SAMBA_BRANCH" "$SAMBA_REPO" /tmp/sambabuild/samba
  cd /tmp/sambabuild/samba
  # libzfs7 / libzfs7-devel / libnvpair3 / libuutil3 are satisfied by the
  # openzfs debs installed above (via their Provides).
  sudo mk-build-deps --install --remove \
    --tool 'apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y' debian/control
  DEB_BUILD_OPTIONS="parallel=$NPROC" dpkg-buildpackage -us -uc -b
  mkdir -p /tmp/samba-debs
  find /tmp/sambabuild -maxdepth 1 -name '*.deb' -exec cp -t /tmp/samba-debs/ {} +
fi
sudo apt-get install -y /tmp/samba-debs/*.deb
echo "::endgroup::"

############################################################
# 3) TrueNAS SSSD  (this repo)
############################################################
echo "::group::TrueNAS SSSD"
cd ~/sssd
# Pull the upstream SSSD sources (version pinned in fetch.sh) into the tree.
./fetch.sh

# Install sssd's build-deps the same way the TrueNAS build does -- NO apt
# pinning. truenas-samba (installed above) Conflicts the Debian ldb/talloc/
# tevent/tdb runtime libs, so apt cannot install Debian's libldb-dev/etc. (they
# would pull the conflicting runtime) and resolves them from truenas-samba's
# Provides instead. That resolution is exactly what this job is meant to test,
# so it is left to happen on its own.
sudo mk-build-deps --install --remove \
  --tool 'apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y' debian/control

# Read-only assertion (does NOT change what is installed): if a stock Debian
# samba-stack lib ended up installed, sssd would be linked against Debian rather
# than truenas-samba -- fail the run so the regression is visible.
intruders=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' \
              libldb2 libtalloc2 libtevent0 libtevent0t64 libtdb1 2>/dev/null \
            | awk '$2 == "installed" { print $1 }' || true)
if [ -n "$intruders" ]; then
  echo "FATAL: stock Debian samba-stack lib(s) installed: $intruders"
  echo "sssd would be built against Debian, not truenas-samba. Aborting."
  exit 1
fi
echo "OK: ldb/talloc/tevent/tdb resolve to truenas-samba, not Debian."

DEB_BUILD_OPTIONS="parallel=$NPROC" dpkg-buildpackage -us -uc -b

# sssd debs land in the parent of ~/sssd (i.e. $HOME).
mkdir -p /tmp/out
find "$HOME" -maxdepth 1 -name '*.deb' -exec cp -t /tmp/out/ {} +
echo "Built SSSD packages:"
ls -la /tmp/out

# Verify the package installs cleanly on top of the truenas-samba/zfs stack.
sudo apt-get install -y /tmp/out/truenas-sssd*.deb
echo "::endgroup::"

echo "Pipeline complete."
