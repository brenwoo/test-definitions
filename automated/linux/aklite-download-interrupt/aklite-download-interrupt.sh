#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2021 Foundries.io Ltd.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
DEVICE_NAME=$(</etc/hostname)
TARGET=""

usage() {
	echo "\
	Usage: $0
		     -t <target> [-n <device name>]

	-n <device name>
		This is the name of the registered device
	-t <target>
		This is the target that is expected to be active
	"
}

while getopts "n:t:h" opts; do
	case "$opts" in
		n) DEVICE_NAME="${OPTARG}";;
		t) TARGET="${OPTARG}";;
		h|*) usage ; exit 1 ;;
	esac
done

if [ -z "${TARGET}" ]; then
    warn_msg "TARGET variable is missing"
fi

! check_root && error_msg "You need to be root to run this script."
create_out_dir "${OUTPUT}"

# configure aklite callback
cp aklite-callback.sh /var/sota/
chmod 755 /var/sota/aklite-callback.sh

mkdir -p /etc/sota/conf.d
cp z-99-aklite-callback.toml /etc/sota/conf.d/
report_pass "create-aklite-callback"
# create signal files
touch /var/sota/ota.signal
touch /var/sota/ota.result
report_pass "create-signal-files"
# run autoregistration script
lmp-device-auto-register
check_return "lmp-device-auto-register" || error_fatal "Unable to register device"

# wait for 'download-pre' signal
SIGNAL=$(</var/sota/ota.signal)
while [ ! "${SIGNAL}" = "download-pre" ]
do
	echo "Sleeping 1s"
	sleep 1
	cat /var/sota/ota.signal
	SIGNAL=$(</var/sota/ota.signal)
	echo "SIGNAL: ${SIGNAL}."
done
report_pass "download-pre-received"
echo "Sleeping 10s"

FOUND=0

while [ ! "${FOUND}" -eq 1 ]
do


    # sleep 5 min
    echo "Sleeping 1s"
    date
    sleep 1

    # check if aktualizr-lite log contains timeout
    journalctl --no-pager -u aktualizr-lite
    echo "********************"
    journalctl --no-pager -u aktualizr-lite | grep "ostree-pull: Receiving objects:"
    if [ "$?" -eq 0 ]; then
        echo "Setting FOUND=1"
        FOUND=1
    fi
done

exit 0
