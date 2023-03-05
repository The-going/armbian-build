#!/usr/bin/env bash
# check_loop_device <device_node>
#
check_loop_device() {

	local device=$1
	if [[ ! -b $device ]]; then
		if [[ $CONTAINER_COMPAT == yes && -b /tmp/$device ]]; then
			display_alert "Creating device node" "$device"
			mknod -m0660 "${device}" b "0x$(stat -c '%t' "/tmp/$device")" "0x$(stat -c '%T' "/tmp/$device")"
		else
			exit_with_error "Device node $device does not exist"
		fi
	fi

}

# write_uboot <loopdev>
#
write_uboot() {

	local loop=$1 revision
	display_alert "Writing U-boot bootloader" "$loop" "info"
	TEMP_DIR=$(mktemp -d || exit 1)
	chmod 700 ${TEMP_DIR}
	revision=${REVISION}
	if [[ -n $UBOOT_VERSION ]]; then
		revision=${UBOOT_VERSION}
	fi

	local uboot_pkg_file="$(find ${DEB_STORAGE}/${RELEASE}/linux-u-boot/ -name ${CHOSEN_UBOOT}_${revision}_${ARCH}.deb)"

	if dpkg -x $uboot_pkg_file ${TEMP_DIR}/ ; then
		# source platform install to read $DIR
		source ${TEMP_DIR}/usr/lib/u-boot/platform_install.sh
		write_uboot_platform "${TEMP_DIR}${DIR}" "$loop"
		[[ $? -ne 0 ]] && exit_with_error "U-boot bootloader failed to install" "@host"
	else
		exit_with_error "U-boot package not found" "${CHOSEN_UBOOT}_${revision}_${ARCH}.deb"
	fi
	rm -rf ${TEMP_DIR}

}
