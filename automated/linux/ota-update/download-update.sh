#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2021 Foundries.io Ltd.

# shellcheck disable=SC1091
. ./sh-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
TYPE="kernel"
UBOOT_VAR_TOOL=fw_printenv
export UBOOT_VAR_TOOL
UBOOT_VAR_SET_TOOL=fw_setenv
export UBOOT_VAR_SET_TOOL
PACMAN_TYPE="ostree+compose_apps"

usage() {
	echo "\
	Usage: $0 [-t <kernel|uboot>] [-u <u-boot var read>] [-s <u-boot var set>] [-o <ostree|ostree+compose_apps>]

    -t <kernel|uboot>
        This determines type of upgrade test performed:
        kernel: perform OTA upgrade without forcing firmware upgrade
        uboot: force firmware upgrade
    -u <u-boot variable read tool>
        Set the name of the tool to read u-boot variables
        On the unsecured systems it will usually be
        fw_printenv. On secured systems it might be
        fiovb_printenv
    -s <u-boot variable set tool>
        Set the name of the tool to set u-boot variables
        On the unsecured systems it will usually be
        fw_setenv. On secured systems it might be
        fiovb_setenv
    -o ostree or ostree+compose_apps rollback
        These change the 'type' variable in 'pacman' section
        of the final .toml file used by aklite. Default is
        ostree+compose_apps
	"
}

while getopts "t:u:s:o:h" opts; do
	case "$opts" in
        t) TYPE="${OPTARG}";;
        u) UBOOT_VAR_TOOL="${OPTARG}";;
        s) UBOOT_VAR_SET_TOOL="${OPTARG}";;
        o) PACMAN_TYPE="${OPTARG}";;
        h|*) usage ; exit 1 ;;
	esac
done

# the script works only on builds with aktualizr-lite
# and lmp-device-auto-register

! check_root && error_msg "You need to be root to run this script."
create_out_dir "${OUTPUT}"

SECONDARY_BOOT_VAR_NAME="fiovb.is_secondary_boot"
if [ "${UBOOT_VAR_TOOL}" != "fw_printenv" ]; then
    SECONDARY_BOOT_VAR_NAME="is_secondary_boot"
fi

ref_bootcount_before_download=0
ref_rollback_before_download=0
ref_bootupgrade_available_before_download=0
ref_upgrade_available_before_download=0
ref_fiovb_is_secondary_boot_before_download=0
ref_bootcount_after_download=0
ref_rollback_after_download=0
ref_bootupgrade_available_after_download=0
ref_upgrade_available_after_download=1
ref_fiovb_is_secondary_boot_after_download=0
if [ "${TYPE}" = "uboot" ]; then
    ref_bootupgrade_available_after_download=1
fi

# configure aklite callback
cp aklite-callback.sh /var/sota/
chmod 755 /var/sota/aklite-callback.sh

mkdir -p /etc/sota/conf.d
if [ "${PACMAN_TYPE}" = "ostree" ]; then
    cp z-99-aklite-callback-ostree.toml /etc/sota/conf.d/
else
    cp z-99-aklite-callback.toml /etc/sota/conf.d/
fi
report_pass "${TYPE}-create-aklite-callback"
# create signal files
touch /var/sota/ota.signal
touch /var/sota/ota.result
report_pass "${TYPE}-create-signal-files"

#systemctl mask aktualizr-lite
# enabling lmp-device-auto-register will fail because aklite is masked
systemctl enable --now lmp-device-auto-register || error_fatal "Unable to register device"
# aktualizr-lite update
# TODO: check if there is an update to download
# if there isn't, terminate the job
# use "${upgrade_available_after_download}" for now. Find a better solution later

while ! systemctl is-active aktualizr-lite; do
    echo "Waiting for aktualizr-lite to start"
    sleep 1
done
# add some delay so aklite can setup variables
sleep 5

# u-boot variables change when aklite starts (at least on some devices)
# check u-boot variables to ensure we're on freshly flashed device
bootcount_before_download=$(uboot_variable_value bootcount)
compare_test_value "${TYPE}_bootcount_before_download" "${ref_bootcount_before_download}" "${bootcount_before_download}"
rollback_before_download=$(uboot_variable_value rollback)
compare_test_value "${TYPE}_rollback_before_download" "${ref_rollback_before_download}" "${rollback_before_download}"
upgrade_available_before_download=$(uboot_variable_value upgrade_available)
compare_test_value "${TYPE}_upgrade_available_before_download" "${ref_upgrade_available_before_download}" "${upgrade_available_before_download}"

if [ -f /usr/lib/firmware/version.txt ]; then
    # boot firmware is upgreadable
    . /usr/lib/firmware/version.txt
    bootupgrade_available_before_download=$(uboot_variable_value bootupgrade_available)
    compare_test_value "${TYPE}_bootupgrade_available_before_download" "${ref_bootupgrade_available_before_download}" "${bootupgrade_available_before_download}"
    bootfirmware_version_before_download=$(uboot_variable_value bootfirmware_version)
    # shellcheck disable=SC2154
    compare_test_value "${TYPE}_bootfirmware_version_before_download" "${bootfirmware_version}" "${bootfirmware_version_before_download}"
    fiovb_is_secondary_boot_before_download=$(uboot_variable_value "${SECONDARY_BOOT_VAR_NAME}")
    compare_test_value "${TYPE}_fiovb_is_secondary_boot_before_download" "${ref_fiovb_is_secondary_boot_before_download}" "${fiovb_is_secondary_boot_before_download}"
else
    report_skip "${TYPE}_bootupgrade_available_before_download"
    report_skip "${TYPE}_bootfirmware_version_before_download"
    report_skip "${TYPE}_fiovb_is_secondary_boot_before_download"
fi

if [ "${TYPE}" = "uboot" ]; then
    # manually set boot firmware version to 0
    "${UBOOT_VAR_SET_TOOL}" bootfirmware_version 0
fi

# wait for 'install-post' signal
SIGNAL=$(</var/sota/ota.signal)
while [ ! "${SIGNAL}" = "install-post" ]
do
	echo "Sleeping 1s"
	sleep 1
	cat /var/sota/ota.signal
	SIGNAL=$(</var/sota/ota.signal)
	echo "SIGNAL: ${SIGNAL}."
done
report_pass "${TYPE}-install-post-received"

# check variables after download is completed
bootcount_after_download=$(uboot_variable_value bootcount)
compare_test_value "${TYPE}_bootcount_after_download" "${ref_bootcount_after_download}" "${bootcount_after_download}"
rollback_after_download=$(uboot_variable_value rollback)
compare_test_value "${TYPE}_rollback_after_download" "${ref_rollback_after_download}" "${rollback_after_download}"
upgrade_available_after_download=$(uboot_variable_value upgrade_available)
compare_test_value "${TYPE}_upgrade_available_after_download" "${ref_upgrade_available_after_download}" "${upgrade_available_after_download}"
if [ -f /usr/lib/firmware/version.txt ]; then
    . /usr/lib/firmware/version.txt
    bootupgrade_available_after_download=$(uboot_variable_value bootupgrade_available)
    compare_test_value "${TYPE}_bootupgrade_available_after_download" "${ref_bootupgrade_available_after_download}" "${bootupgrade_available_after_download}"
    # shellcheck disable=SC2154
    ref_bootfirmware_version_after_download="${bootfirmware_version}"
    if [ "${TYPE}" = "uboot" ]; then
        ref_bootfirmware_version_after_download=0
    fi
    bootfirmware_version_after_download=$(uboot_variable_value bootfirmware_version)
    # shellcheck disable=SC2154
    compare_test_value "${TYPE}_bootfirmware_version_after_download" "${ref_bootfirmware_version_after_download}" "${bootfirmware_version_after_download}"
    fiovb_is_secondary_boot_after_download=$(uboot_variable_value "${SECONDARY_BOOT_VAR_NAME}")
    compare_test_value "${TYPE}_fiovb_is_secondary_boot_after_download" "${ref_fiovb_is_secondary_boot_after_download}" "${fiovb_is_secondary_boot_after_download}"
else
    report_skip "${TYPE}_bootupgrade_available_after_download"
    report_skip "${TYPE}_bootfirmware_version_after_download"
    report_skip "${TYPE}_fiovb_is_secondary_boot_after_download"
fi

UPGRADE_AVAILABLE="${upgrade_available_after_download}"
if [ "${TYPE}" = "uboot" ]; then
    UPGRADE_AVAILABLE="${bootupgrade_available_after_download}"
fi

if [ "${UPGRADE_AVAILABLE}" -ne 1 ]; then
    lava-test-raise "No-update-available-${TYPE}"
fi
