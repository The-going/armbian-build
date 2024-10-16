#!/bin/bash
#
# Copyright (c) 2013-2021 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# DO NOT EDIT THIS FILE
# use configuration files like config-default.conf to set the build configuration
# check Armbian documentation https://docs.armbian.com/ for more info

SRC="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# check for whitespace in ${SRC} and exit for safety reasons
grep -q "[[:space:]]" <<< "${SRC}" && {
	echo "\"${SRC}\" contains whitespace. Not supported. Aborting." >&2
	exit 1
}

cd "${SRC}" || exit

if [[ -f "${SRC}"/lib/import-functions.sh ]]; then

	# shellcheck source=lib/import-functions.sh
	source "${SRC}"/lib/import-functions.sh

else

	echo "Error: missing build directory structure"
	echo "Please clone the full repository https://github.com/armbian/build/"
	exit 255

fi

cli_entrypoint "$@"
