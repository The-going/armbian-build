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

	local loop=$1
	display_alert "Writing U-boot bootloader" "$loop" "info"
	TEMP_DIR=$(mktemp -d) || TEMP_DIR=$(mktemp -d "${SRC}"/.tmp/tmp_XXXX)
	chmod 700 ${TEMP_DIR}

	local uboot_pkg_file="$(
			find ${DEB_STORAGE}/${RELEASE}/linux-u-boot/ \
				-name ${CHOSEN_UBOOT}_${UBOOT_VERSION}_${ARCH}.deb
		)"
	[[ -f "$uboot_pkg_file" ]] ||
	exit_with_error "U-boot package not found" "${CHOSEN_UBOOT}_${UBOOT_VERSION}_${ARCH}.deb"

	if dpkg -x $uboot_pkg_file ${TEMP_DIR}/ ; then
		# source platform install to read $DIR
		source ${TEMP_DIR}/usr/lib/u-boot/platform_install.sh
		write_uboot_platform "${TEMP_DIR}${DIR}" "$loop"
		[[ $? -ne 0 ]] && exit_with_error "write_uboot_platform ${TEMP_DIR}${DIR} $loop" "failed"
	else
		exit_with_error "Extracting ${CHOSEN_UBOOT}_${UBOOT_VERSION}_${ARCH}.deb to ${TEMP_DIR}/" "failed"
	fi
	rm -rf ${TEMP_DIR}

}
