#!/usr/bin/env bash
# Copyright 2023 - Marco Trevisan
# Released under the GPLv3 terms
#
# A simple tool to simulate PAM authentication using SSSD smartcard settings.
#
# To be used with softhsm2 smart cards generators from
# https://gist.github.com/3v1n0/287d02ca8e03936f1c7bba992173d47a
#
# Origin: https://gist.github.com/3v1n0/d7bc0f10cf44a11288648ae9d228430d

set -xe

if [ -z "${AUTOPKGTEST_NORMAL_USER}" ]; then
    adduser --quiet --disable-password _sssduser
    AUTOPKGTEST_NORMAL_USER="_sssduser"
fi

export DEBIAN_FRONTEND=noninteractive

required_tools=(
    pamtester      # debian package: pamtester
    softhsm2-util  # debian package: softhsm2
    sssd           # debian package: sssd
)

if [[ ! -v OFFLINE_MODE ]]; then
  required_tools+=(
    wget  # debian package: wget
  )
fi

for cmd in "${required_tools[@]}"; do
  if ! command -v "$cmd" > /dev/null; then
    echo "Tool $cmd missing"
    exit 1
  fi
done

PIN=${PIN:-123456}
tmpdir=${TEST_TMPDIR:-$(mktemp -d -t "sssd-softhsm2-certs-XXXXXX")}
backupsdir=

alternative_pam_configs=(
  sss-smart-card-optional
  sss-smart-card-required
)

declare -a restore_paths
declare -a delete_paths

function restore_changes() {
  for path in "${restore_paths[@]}"; do
    local original_path
    original_path="/$(realpath --strip --relative-base="$backupsdir" "$path")"
    rm "$original_path" && mv "$path" "$original_path" || true
  done

  for path in "${delete_paths[@]}"; do
    rm -f "$path"
    #find "$(dirname "$path")" -empty -delete || true
  done

  pam-auth-update --disable "${alternative_pam_configs[@]}" || return 2

  if [ -e /etc/sssd/sssd.conf ]; then
    chmod 600 /etc/sssd/sssd.conf || return 1
    systemctl restart sssd || true
  else
    systemctl stop sssd || true
  fi

  if [ -e /etc/softhsm/softhsm2.conf ]; then
    chmod 600 /etc/softhsm/softhsm2.conf || return 1
  fi

  rm -rf "$tmpdir"
}

function backup_file() {
  if [ -z "$backupsdir" ]; then
    backupsdir=$(mktemp -d -t "sssd-softhsm2-backups-XXXXXX")
  fi

  if [ -e "$1" ]; then
    local back_dir="$backupsdir/$(dirname "$1")"
    local back_path="$back_dir/$(basename "$1")"
    [ ! -e "$back_path" ] || return 1

    mkdir -p "$back_dir" || return 1
    cp -a "$1" "$back_path" || return 1

    restore_paths+=("$back_path")
  else
    delete_paths+=("$1")
  fi
}

function handle_exit() {
  exit_code=$?

  restore_changes || return 1

  if [ $exit_code = 0 ]; then
    rm -rf "$backupsdir"
    set +x
    echo "Script completed successfully!"
  else
    set +x
    echo "Script failed, check the log!"
    echo "  Backup preserved at $backupsdir"
    echo "  PAM Log: /var/log/auth.log"
    echo "  SSSD PAM Log: /var/log/sssd/sssd_pam.log"
    echo "  SSSD p11_child Log: /var/log/sssd/p11_child.log"
  fi
}

trap 'handle_exit' EXIT

tester="$(dirname "$0")"/sssd-softhism2-certificates-tests.sh
if [ ! -e "$tester" ] && [[ ! -v OFFLINE_MODE ]]; then
  echo "Required $tester missing, we're downloading it..."
  tester="$tmpdir/sssd-softhism2-certificates-tests.sh"
  wget -q -c https://gist.github.com/3v1n0/287d02ca8e03936f1c7bba992173d47a/raw/sssd-softhism2-certificates-tests.sh \
    -O "$tester"
  [ -e "$tester" ] || exit 1
elif [ ! -e "$tester" ] && [[ -v OFFLINE_MODE ]]; then
  echo "Required $tester missing"
  exit 1
fi

export PIN TEST_TMPDIR="$tmpdir" GENERATE_SMART_CARDS=1 KEEP_TEMPORARY_FILES=1 NO_SSSD_TESTS=1
bash "$tester"

find "$tmpdir" -type d -exec chmod 777 {} \;
find "$tmpdir" -type f -exec chmod 666 {} \;

backup_file /etc/sssd/sssd.conf
rm -f /etc/sssd/sssd.conf

user_home="$(runuser -u "${AUTOPKGTEST_NORMAL_USER}" -- sh -c 'echo ~')"
mkdir -p "$user_home"
chown "${AUTOPKGTEST_NORMAL_USER}:${AUTOPKGTEST_NORMAL_USER}" "$user_home"

user_config="$(runuser -u "${AUTOPKGTEST_NORMAL_USER}" -- sh -c 'echo ${XDG_CONFIG_HOME:-~/.config}')"
system_config="/etc"

softhsm2_conf_paths=(
  "${AUTOPKGTEST_NORMAL_USER}:$user_config/softhsm2/softhsm2.conf"
  "root:$system_config/softhsm/softhsm2.conf"
)

for path_pair in "${softhsm2_conf_paths[@]}"; do
  IFS=":" read -r -a path <<< "${path_pair}"
  path="${path[1]}"
  backup_file "$path"
  rm -f "$path"
done

function test_authentication() {
  pam_service="$1"
  certificate_config="$2"
  ca_db="$3"
  verification_options="$4"

  mkdir -p -m 700 /etc/sssd

  echo "Using CA DB '$ca_db' with verification options: '$verification_options'"

  cat <<EOF > /etc/sssd/sssd.conf || return 2
[sssd]
enable_files_domain = True
services = pam
#certificate_verification = $verification_options

[certmap/implicit_files/${AUTOPKGTEST_NORMAL_USER}]
matchrule = <SUBJECT>.*Test Organization.*

[pam]
pam_cert_db_path = $ca_db
pam_cert_verification = $verification_options
pam_cert_auth = True
pam_verbosity = 10
debug_level = 10
EOF

  chmod 600 /etc/sssd/sssd.conf || return 2

  for path_pair in "${softhsm2_conf_paths[@]}"; do
    IFS=":" read -r -a path <<< "${path_pair}"
    user="${path[0]}"
    path="${path[1]}"

    runuser -u "$user" -- mkdir -p "$(dirname "$path")" || return 2
    runuser -u "$user" -- ln -sf "$certificate_config" "$path" || return 2
    runuser -u "$user" -- softhsm2-util --show-slots | grep "Test Organization" \
      || return 2
  done

  systemctl restart sssd || return 2

  pam-auth-update --disable "${alternative_pam_configs[@]}" || return 2

  for alternative in "${alternative_pam_configs[@]}"; do
    pam-auth-update --enable "$alternative" || return 2
    cat /etc/pam.d/common-auth

    echo -n -e "$PIN" | runuser -u "${AUTOPKGTEST_NORMAL_USER}" -- \
      pamtester -v "$pam_service" "${AUTOPKGTEST_NORMAL_USER}" authenticate  || return 2
    echo -n -e "$PIN" | runuser -u "${AUTOPKGTEST_NORMAL_USER}" -- \
      pamtester -v "$pam_service" "" authenticate  || return 2

    if echo -n -e "wrong${PIN}" | runuser -u "${AUTOPKGTEST_NORMAL_USER}" -- \
        pamtester -v "$pam_service" "${AUTOPKGTEST_NORMAL_USER}" authenticate; then
      echo "Unexpected pass!"
      return 2
    fi

    if echo -n -e "wrong${PIN}" | runuser -u "${AUTOPKGTEST_NORMAL_USER}" -- \
        pamtester -v "$pam_service" "" authenticate; then
      echo "Unexpected pass!"
      return 2
    fi

    if echo -n -e "$PIN" | pamtester -v "$pam_service" root authenticate; then
      echo "Unexpected pass!"
      return 2
    fi
  done
}

test_authentication \
  login \
  "$tmpdir/softhsm2-test-root-CA-trusted-certificate-0001.conf" \
  "$tmpdir/test-full-chain-CA.pem"

test_authentication \
  login \
  "$tmpdir/softhsm2-test-sub-intermediate-CA-trusted-certificate-0001.conf" \
  "$tmpdir/test-full-chain-CA.pem"

test_authentication \
  login \
  "$tmpdir/softhsm2-test-sub-intermediate-CA-trusted-certificate-0001.conf" \
  "$tmpdir/test-sub-intermediate-CA.pem" \
  "partial_chain"

