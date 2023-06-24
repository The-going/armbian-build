#!/usr/bin/env bash


build_packages_per_release_arch() {
	local target_release="bullseye bookworm focal jammy lunar sid"
	local target_arch="armhf arm64 amd64"
	local release arch

	for release in $target_release; do
		for arch in $target_arch; do
			chroot_build_packages release=$release arch=$arch
		done
	done
}

# chroot_build_packages
#
chroot_build_packages() {
	local built_ok=()
	local failed=()
	while [[ "${1}" == *=* ]]; do
		p=${1%%=*}
		v=${1##*=}
		shift
		eval "local $p=\"$v\""
	done
	local selected_packages=$@
	mkdir -p ${SRC}/cache/buildpkg

	local release="${release:-$RELEASE}"
	local arch="${arch:-$ARCH}"

	display_alert "Starting package building process" "$release/$arch" "info"
	if [[ -n "$selected_packages" ]]; then
		display_alert "Selected packages for chroot: " "$selected_packages" "info"
	else
		exit_with_error "No packages selected"
	fi

	local t_name=${release}-${arch}-${CHROOT_CACHE_VERSION}

	if [ "$(findmnt -n -o FSTYPE --target /tmp)"  == "tmpfs" ]; then
	   tmpsyze=$(($(findmnt -n -b -o AVAIL --target /tmp) / (1024 * 1024)))
	   display_alert "Size /tmp as tmpfs" "$tmpsyze M" "ext"
	   [[ $tmpsyze -ge 8000 ]] && TMPBASEDIR="/tmp"
	else
	   TMPBASEDIR="${SRC}/.tmp"
	fi

	# Create a clean environment archive if it does not exist.
	if [ ! -f "${SRC}/cache/buildpkg/${t_name}.tar.xz" ]; then
		create_clean_environment_archive $release $arch ${CHROOT_CACHE_VERSION}
	fi

	# Unpack the clean environment archive, if it exists.
	if [ -f "${SRC}/cache/buildpkg/${t_name}.tar.xz" ]; then
		local tmp_dir=$(mktemp -d ${TMPBASEDIR}/build-XXXXX)
		(
			cd $tmp_dir
			display_alert "Unpack the clean environment" "${t_name}.tar.xz" "info"
			tar -xJf "${SRC}/cache/buildpkg/${t_name}.tar.xz" ||
				exit_with_error "Is not extracted" "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		)
		build_dir="$tmp_dir/${t_name}"
	else
		exit_with_error "Creating chroot failed" "${release}/${arch}"
	fi

	[[ -f /var/run/distcc/"${release}-${arch}".pid ]] &&
		kill "$(< "/var/run/distcc/${release}-${arch}.pid")" > /dev/null 2>&1

	if distcc_build_implement ; then
		preparing_distccd "${release}" "${arch}"
		local distcc_bindaddr="127.0.0.2"
		# DISTCC_TCP_DEFER_ACCEPT=0
		DISTCC_CMDLIST=/tmp/distcc/${release}-${arch}/cmdlist \
				TMPDIR=/tmp/distcc distccd --daemon \
				--pid-file "/var/run/distcc/${release}-${arch}.pid" \
				--listen $distcc_bindaddr --allow 127.0.0.0/24 \
				--log-file "/tmp/distcc/${release}-${arch}.log" --user distccd
	fi

	[[ -d $build_dir ]] ||
		exit_with_error "Clean Environment is not visible" "$build_dir"

	local t=$build_dir/root/.update-timestamp
	if [[ ! -f ${t} || $((($(date +%s) - $(< "${t}")) / 86400)) -gt 7 ]]; then
		display_alert "Upgrading packages" "$release/$arch" "info"
		systemd-nspawn -a -q \
			-D "${build_dir}" \
			/bin/bash -c "apt-get -q update; apt-get -q -y upgrade; apt-get clean"
		date +%s > "${t}"
		display_alert "Repack a clean Environment archive after upgrading" "${t_name}.tar.xz" "info"
		rm "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		(
			tar -cp --directory="${tmp_dir}/" ${t_name} |
				pv -p -b -r -s "$(du -sb "${tmp_dir}/${t_name}" | cut -f1)" |
				pixz -4 > "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		)
		# create list of installed packages
		rm "${SRC}/cache/buildpkg/${t_name}.list"
		chroot "${tmp_dir}/${t_name}" /bin/bash -c \
			"dpkg -l | awk '/^ii/ { print \$2\",\"\$3 }'" > \
			"${SRC}/cache/buildpkg/${t_name}.list" 2>&1
	fi

	local config_for_packages=""
	local src_dir

	for package_name in $selected_packages; do
		# Processing variables for three variants of the build scenario.
		if [ -f "${USERPATCHES_PATH}"/packages/deb-build/${package_name}.conf ]; then
			config_for_packages="${USERPATCHES_PATH}"/packages/deb-build/${package_name}.conf
			src_dir="${USERPATCHES_PATH}"/packages/deb-build/${package_name}
		elif [ -f "${SRC}"/packages/deb-build/${package_name}.conf ]; then
			config_for_packages="${SRC}"/packages/deb-build/${package_name}.conf
			src_dir="${SRC}"/packages/deb-build/${package_name}
		elif [ -f "${USERPATCHES_PATH}"/packages/deb-build/${package_name}/debian/watch ]; then
			src_dir="${USERPATCHES_PATH}"/packages/deb-build/${package_name}
			config_for_packages="watch"
		elif [ -f "${SRC}"/packages/deb-build/${package_name}/debian/watch ]; then
			src_dir="${SRC}"/packages/deb-build/${package_name}
			config_for_packages="watch"
		else
			display_alert "Attempt to rebuild the system package" "${package_name}" "wrn"
			config_for_packages="src"
			src_dir="${USERPATCHES_PATH}"/packages/deb-build/${package_name}
			mkdir -p $src_dir; chmod 777 $src_dir
		fi

		unset package_repo package_ref package_builddeps \
			  package_install_chroot package_install_target \
			  package_upstream_version needs_building pkg_target_dir \
			  package_component "package_builddeps_${release}"

		if [ -f $config_for_packages ]; then
			source "${config_for_packages}"
		fi

		local pkg_target_dir="${DEB_STORAGE}/${release}/${package_name}"
		mkdir -p "${pkg_target_dir}"
		local src_cache_dir="${SRC}"/cache/sources/$package_name
		mkdir -p "${src_cache_dir}"

		# check if needs building
		if [[ -f $(find "${pkg_target_dir}/" -name ${package_name}'*'${arch}.deb) ]]; then
			display_alert "Packages are up to date" "$package_name $release/$arch" "info"
			continue
		fi

		# Delete the environment if there was a build in it.
		# And unpack the clean environment again.
		if [[ -f "${build_dir}"/root/build.sh ]] &&
		   [[ -d $tmp_dir ]] && [[ "${CHROOT_CACHE_VERSION}" == clean ]]; then
			rm -rf $tmp_dir
			local tmp_dir=$(mktemp -d ${TMPBASEDIR}/build-XXXXX)
			(
				cd $tmp_dir
				display_alert "Unpack the clean environment" "${t_name}.tar.xz" "info"
				tar -xJf "${SRC}/cache/buildpkg/${t_name}.tar.xz" ||
					exit_with_error "Is not extracted" "${SRC}/cache/buildpkg/${t_name}.tar.xz"
			)
			local build_dir="$tmp_dir/${t_name}"
		fi

		display_alert "Building packages" "$package_name $release/$arch" "ext"
		ts=$(date +%s)
		local dist_builddeps_name="package_builddeps_${release}"
		[[ -v $dist_builddeps_name ]] && package_builddeps="${package_builddeps} ${!dist_builddeps_name}"

		local pkg_linux_libcdev
		if ! pkg_linux_libcdev="$(
				find ${DEB_STORAGE}/${release}/linux-${BRANCH}/ \
						-name 'linux-libc-dev*' 2>/dev/null)"; then
			display_alert "Used system pkg:" " linux-libc-dev " "info"
		elif [ $(echo -e "$pkg_linux_libcdev" | wc -l) -gt 1 ]; then
			display_alert "An ambiguous situation." "Multiple linux-libc-dev files found" "wrn"
			display_alert "Used system pkg:" " linux-libc-dev " "info"
		else
			display_alert "Used pkg:" " $pkg_linux_libcdev " "info"
			cp $pkg_linux_libcdev "${build_dir}"/root/
			file_linux_libcdev="/root/$(basename $pkg_linux_libcdev)"
		fi

		if [[ "${package_repo%:*}" == http* ]] && [ -n "$package_ref" ]; then
			fetch_from_repo "$package_repo" "$package_name" "$package_ref"
		elif [ "$config_for_packages" == "watch" ]; then
			check_debian_build_version "${src_dir}" "${src_cache_dir}"
		fi

		# create build script
		LOG_OUTPUT_FILE=/root/build-"${package_name}".log
		create_build_script
		unset LOG_OUTPUT_FILE

		if [ "$CMDLINE" != "" ]; then
			command_line='/bin/bash'
		else
			command_line='/bin/bash -c \"/root/build.sh\"'
		fi

		eval systemd-nspawn -a -q \
				--capability=CAP_MKNOD -D "${build_dir}" \
				--tmpfs=/root/build \
				--tmpfs=/tmp:mode=777 \
				--bind "$(dirname $src_dir)"/:/root/overlay \
				--bind-ro "${SRC}"/cache/sources/:/root/sources \
				$command_line \
				${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/buildpkg.log'} 2>&1 \
				';EVALPIPE=(${PIPESTATUS[@]})'

		if [[ ${EVALPIPE[0]} -ne 0 ]]; then
			failed+=("$package_name:$release/$arch")
			mv "${build_dir}"/root/build.sh "$DEST/${LOG_SUBPATH}/"
		else
			built_ok+=("$package_name:$release/$arch")
			mv "${build_dir}"/root/{*.deb,*.changes,*.buildinfo} "${pkg_target_dir}/"
		fi

		mv "${build_dir}"/root/*.log "$DEST/${LOG_SUBPATH}/"

		te=$(date +%s)
		display_alert "Build time $package_name " " $(($te - $ts)) sec." "info"
	done

	# Delete a temporary directory
	if [ -d $tmp_dir ]; then rm -rf $tmp_dir; fi

	# cleanup for distcc
	if [ -f /var/run/distcc/${release}-${arch}.pid ]; then
		kill $(< /var/run/distcc/${release}-${arch}.pid)
	fi

	if [[ ${#built_ok[@]} -gt 0 ]]; then
		display_alert "Following packages were built without errors" "" "info"
		for p in ${built_ok[@]}; do
			display_alert "$p"
		done
	fi

	if [[ ${#failed[@]} -gt 0 ]]; then
		display_alert "Following packages failed to build" "" "wrn"
		for p in ${failed[@]}; do
			display_alert "$p"
		done
	fi
}

# Check the debian build version
# depends: devscripts
#   "$1" - Full path to the pkgname/debian directory
#   "$2" - Full path to target build directory
check_debian_build_version() {
	local src_dir="$1"
	local src_cache_dir="$2"

	for n in $(
		cd $src_dir
		uscan -v --destdir "$src_cache_dir" | \
		awk '$1 ~ /^version|^package|newversion/{sub(/\$/,"",$1); print $1 $2 $3}'
		)
	do
		eval "local $n"
	done

	if [[ -v newversion ]];then
		display_alert "package=:${package}\n" "newversion=${newversion}\n" "line"
		local newtarball=$(find ${src_cache_dir}/ -name ${package}_${newversion}.orig.tar'*')
		display_alert "\n" "newtarball=${newtarball}\n" "line"
	fi

	local tarball=$(find ${src_cache_dir}/ -name ${package}_${version}.orig.tar'*')
	if [ "$tarball" == "" ]; then
		$(cd $src_dir; uscan --download-current-version --destdir "$src_cache_dir")
		tarball=$(find ${src_cache_dir}/ -name ${package}_${version}.orig.tar'*')
	fi

	display_alert "tarball=:${tarball}\n" "" "line"
	PKG_NAME_="$package"
	PKG_NAME_VERSION="$version"

} # apt-cache show devscripts


# create build script
create_build_script() {
	cat <<-EOF > "${build_dir}"/root/build.sh
	#!/bin/bash
	export PATH="/usr/lib/ccache:\$PATH"
	export HOME="/root"
	export DEBIAN_FRONTEND="noninteractive"
	export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
	export DEBFULLNAME="$MAINTAINER"
	export DEBEMAIL="$MAINTAINERMAIL"

	LOG_OUTPUT_FILE=$LOG_OUTPUT_FILE
	$(declare -f display_alert)

	$(declare -f install_pkg_deb)
	EOF

	# distcc is disabled to prevent compilation issues due
	# to different host and cross toolchain configurations
	if distcc_build_implement ; then
		cat <<-EOF >> "${build_dir}"/root/build.sh

		export DISTCC_HOSTS="$distcc_bindaddr"
		export CCACHE_PREFIX="distcc"
		# uncomment for debug
		#export CCACHE_RECACHE="true"
		#export CCACHE_DISABLE="true"
		EOF
	fi

	cat <<EOF>> "${build_dir}"/root/build.sh

	cd /root/build

	if [ -d /root/sources/${package_name}/.git ]; then
		display_alert "Copying sources"
		rsync -aq /root/sources/"${package_name}" /root/build/

	elif [ -f /root/sources/${package_name}/${package_name}-*.tar.gz ]; then
		display_alert "Tarbal exist" "\$(ls /root/sources/${package_name}/*.tar.*)" "info"
	fi

	cd /root/build/"${package_name}"
	# copy overlay / "debianization" files
	[[ -d "/root/overlay/${package_name}/" ]] && rsync -aq /root/overlay/"${package_name}" /root/build/

	package_builddeps="$package_builddeps"
	if [ -z "\$package_builddeps" ]; then
		# Calculate build dependencies by a standard dpkg function
		#echo "\$(dpkg-checkbuilddeps)" >&2
		package_builddeps="\$(dpkg-checkbuilddeps |& awk -F":" '{print \$NF}')"
	fi

	if [[ -n "\${package_builddeps}" ]]; then
		echo "install_pkg_deb verbose \${package_builddeps}" >&2
		install_pkg_deb verbose \${package_builddeps} $file_linux_libcdev
	fi

	# set upstream version
	[[ -n "${package_upstream_version}" ]] && \\
	debchange --preserve --newversion "${package_upstream_version}" "Import from upstream"

	# set local version
	# debchange -l~armbian${REVISION}-${builddate}+ "Custom $VENDOR release"
	debchange -l~${VENDOR}2+ "Custom $VENDOR release"

	display_alert "Building package"
	# Set the number of build threads and certainly send
	# the standard error stream to the log file.
	dpkg-buildpackage -b -us -j${NCPU_CHROOT:-2} 2>>\$LOG_OUTPUT_FILE

	if [[ \$? -eq 0 ]] && \\
		package_version=\$(dpkg-deb -f /root/build/${package_name}_*_${arch}.deb Version); then

		display_alert "Done building" "$package_name (\$package_version) $release/$arch" "ext"
		mv /root/build/${package_name}_\${package_version}_${arch}.* /root 2>/dev/null
		exit 0
	else
		display_alert "Failed building" "$package_name $release/$arch" "err"
		exit 2
	fi
EOF

	chmod +x "${build_dir}"/root/build.sh
}
