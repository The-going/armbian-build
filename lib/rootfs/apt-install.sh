#!/usr/bin/env bash
install_deb_chroot() {

	local name=$1
	local desc=" from repository"

	local version=$(
		chroot "${SDCARD}" /bin/bash -c "apt-cache policy $name | \
			awk '/Candidate:/{print \$2}'"
		)
	desc+=" $(
		chroot "${SDCARD}" /bin/bash -c "apt-cache madison $name | \
			awk -v v=$version '{if(\$3 ~ v) print \$5}'"
	)"
	display_alert "Installing${desc}" "${name/\/root\//} ($version)"

	[[ $NO_APT_CACHER != yes ]] && \
	local apt_extra="-o Acquire::http::Proxy=\"http://${APT_PROXY_ADDR:-localhost:3142}\" -o Acquire::http::Proxy::localhost=\"DIRECT\""

	# when building in bulk from remote, lets make sure we have up2date index
	chroot "${SDCARD}" /bin/bash -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -yqq $apt_extra \
		--no-install-recommends install $name" >> \
		"${DEST}"/${LOG_SUBPATH}/install.log 2>&1

	[[ $? -ne 0 ]] && exit_with_error "Installation of $name failed" "${BOARD} ${RELEASE} ${BUILD_DESKTOP} ${LINUXFAMILY}"

	RET_VERSION=$version
}
