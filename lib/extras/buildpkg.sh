#!/usr/bin/env bash
# create_chroot <target_dir> <release> <arch>
#
create_chroot() {
	local target_dir="$1"
	local release=$2
	local arch=$3
	declare -A qemu_binary apt_mirror components
	qemu_binary['armhf']='qemu-arm-static'
	qemu_binary['arm64']='qemu-aarch64-static'
	apt_mirror['buster']="$DEBIAN_MIRROR"
	apt_mirror['bullseye']="$DEBIAN_MIRROR"
	apt_mirror['bookworm']="$DEBIAN_MIRROR"
	apt_mirror['focal']="$UBUNTU_MIRROR"
	apt_mirror['jammy']="$UBUNTU_MIRROR"
	apt_mirror['kinetic']="$UBUNTU_MIRROR"
	apt_mirror['lunar']="$UBUNTU_MIRROR"
	components['buster']='main,contrib'
	components['bullseye']='main,contrib'
	components['bookworm']='main,contrib'
	components['sid']='main,contrib'
	components['focal']='main,universe,multiverse'
	components['jammy']='main,universe,multiverse'
	components['lunar']='main,universe,multiverse'
	components['kinetic']='main,universe,multiverse'
	display_alert "Creating build chroot" "$release/$arch" "info"
	local includes="ccache,locales,git,ca-certificates,libfile-fcntllock-perl,rsync,python3,distcc,apt-utils"

	# perhaps a temporally workaround
	case $release in
		bullseye | bookworm | sid | focal | jammy | kinetic | lunar)
			includes=${includes}",perl-openssl-defaults,libnet-ssleay-perl"
			;;
	esac

	if [[ $NO_APT_CACHER != yes ]]; then
		local mirror_addr="http://localhost:3142/${apt_mirror[${release}]}"
	else
		local mirror_addr="http://${apt_mirror[${release}]}"
	fi

	mkdir -p "${target_dir}"
	cd "${target_dir}"
	debootstrap --variant=buildd \
		--components="${components[${release}]}" \
		--arch="${arch}" $DEBOOTSTRAP_OPTION \
		--foreign \
		--include="${includes}" "${release}" "${target_dir}" "${mirror_addr}"

	[[ $? -ne 0 || ! -f "${target_dir}"/debootstrap/debootstrap ]] &&
		exit_with_error "Create chroot first stage failed"

	cp /usr/bin/${qemu_binary[$arch]} "${target_dir}"/usr/bin/
	[[ ! -f "${target_dir}"/usr/share/keyrings/debian-archive-keyring.gpg ]] &&
		mkdir -p "${target_dir}"/usr/share/keyrings/ &&
		cp /usr/share/keyrings/debian-archive-keyring.gpg "${target_dir}"/usr/share/keyrings/

	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "/debootstrap/debootstrap --second-stage"'
	[[ $? -ne 0 || ! -f "${target_dir}"/bin/bash ]] && exit_with_error "Create chroot second stage failed"

	[[ -f "${target_dir}"/etc/locale.gen ]] &&
		sed -i '/en_US.UTF-8/s/^# //g' "${target_dir}"/etc/locale.gen
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "locale-gen; update-locale --reset LANG=en_US.UTF-8"'

	create_sources_list "$release" "${target_dir}"
	[[ $NO_APT_CACHER != yes ]] &&
		echo 'Acquire::http { Proxy "http://localhost:3142"; };' > "${target_dir}"/etc/apt/apt.conf.d/02proxy
	cat <<- EOF > "${target_dir}"/etc/apt/apt.conf.d/71-no-recommends
		APT::Install-Recommends "0";
		APT::Install-Suggests "0";
	EOF

	printf '#!/bin/sh\nexit 101' > "${target_dir}"/usr/sbin/policy-rc.d
	chmod 755 "${target_dir}"/usr/sbin/policy-rc.d
	rm "${target_dir}"/etc/resolv.conf 2> /dev/null
	echo "nameserver $NAMESERVER" > "${target_dir}"/etc/resolv.conf
	rm "${target_dir}"/etc/hosts 2> /dev/null
	echo "127.0.0.1 localhost" > "${target_dir}"/etc/hosts
	mkdir -p "${target_dir}"/root/{build,overlay,sources} "${target_dir}"/selinux
	if [[ -L "${target_dir}"/var/lock ]]; then
		rm -rf "${target_dir}"/var/lock 2> /dev/null
		mkdir -p "${target_dir}"/var/lock
	fi
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "/usr/sbin/update-ccache-symlinks"'

	display_alert "Upgrading packages in" "${target_dir}" "info"
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "apt-get -q update; apt-get -q -y upgrade; apt-get clean"'
	date +%s > "$target_dir/root/.update-timestamp"

	# Install some packages with a large list of dependencies after the update.
	# This optimizes the process and eliminates looping when calculating
	# dependencies.
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "apt-get install \
		-q -y --no-install-recommends debhelper devscripts"'

	case $release in
		bullseye | bookworm | sid | focal | hirsute )
			eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
			/bin/bash -c "apt-get install python-is-python3"'
			;;
	esac

	touch "${target_dir}"/root/.debootstrap-complete
	display_alert "Debootstrap complete" "${release}/${arch}" "info"
}

# chroot_prepare_distccd <release> <arch>
#
chroot_prepare_distccd() {
	local release=$1
	local arch=$2
	local dest=/tmp/distcc/${release}-${arch}
	declare -A gcc_version gcc_type
	gcc_version['buster']='8.3'
	gcc_version['bullseye']='9.2'
	gcc_version['bookworm']='10.2'
	gcc_version['sid']='10.2'
	gcc_version['bionic']='5.4'
	gcc_version['focal']='9.2'
	gcc_version['hirsute']='10.2'
	gcc_version['jammy']='12'
	gcc_version['kinetic']='12'
	gcc_version['lunar']='12'
	gcc_type['armhf']='arm-linux-gnueabihf-'
	gcc_type['arm64']='aarch64-linux-gnu-'
	rm -f "${dest}"/cmdlist
	mkdir -p "${dest}"
	local toolchain_path
	toolchain_path=$(find_toolchain "${gcc_type[${arch}]}" "== ${gcc_version[${release}]}")
	ln -sf "${toolchain_path}/${gcc_type[${arch}]}gcc" "${dest}"/cc
	echo "${dest}/cc" >> "${dest}"/cmdlist
	for compiler in gcc cpp g++ c++; do
		echo "${dest}/$compiler" >> "${dest}"/cmdlist
		echo "${dest}/${gcc_type[$arch]}${compiler}" >> "${dest}"/cmdlist
		ln -sf "${toolchain_path}/${gcc_type[${arch}]}${compiler}" "${dest}/${compiler}"
		ln -sf "${toolchain_path}/${gcc_type[${arch}]}${compiler}" "${dest}/${gcc_type[${arch}]}${compiler}"
	done
	mkdir -p /var/run/distcc/
	touch /var/run/distcc/"${release}-${arch}".pid
	chown -R distccd /var/run/distcc/
	chown -R distccd /tmp/distcc
}

# Create a clean environment archive if it does not exist.
#
#	$1: $RELEASE
#	$2: $ARCH
#	$3: ${CHROOT_CACHE_VERSION}
#
create_clean_environment_archive() {
	local release=$1
	local arch=$2
	local t_name=${release}-${arch}-v${3}
	local tmp_dir=$(mktemp -d "${SRC}"/.tmp/debootstrap-XXXXX)

	create_chroot "${tmp_dir}/${t_name}" "${release}" "${arch}"
	display_alert "Create a clean Environment archive" "${t_name}.tar.xz" "info"
	(
		tar -cp --directory="${tmp_dir}/" ${t_name} |
			pv -p -b -r -s "$(du -sb "${tmp_dir}/${t_name}" | cut -f1)" |
			pixz -4 > "${SRC}/cache/buildpkg/${t_name}.tar.xz"
	)
	rm -rf $tmp_dir
}

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

	local t_name=${release}-${arch}-v${CHROOT_CACHE_VERSION}
	local distcc_bindaddr="127.0.0.2"

	# Create a clean environment archive if it does not exist.
	if [ ! -f "${SRC}/cache/buildpkg/${t_name}.tar.xz" ]; then
		create_clean_environment_archive $release $arch ${CHROOT_CACHE_VERSION}
	fi

	# Unpack the clean environment archive, if it exists.
	if [ -f "${SRC}/cache/buildpkg/${t_name}.tar.xz" ]; then
		local tmp_dir=$(mktemp -d "${SRC}"/.tmp/build-XXXXX)
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

	chroot_prepare_distccd "${release}" "${arch}"

	# DISTCC_TCP_DEFER_ACCEPT=0
	DISTCC_CMDLIST=/tmp/distcc/${release}-${arch}/cmdlist \
				TMPDIR=/tmp/distcc distccd --daemon \
				--pid-file "/var/run/distcc/${release}-${arch}.pid" \
				--listen $distcc_bindaddr --allow 127.0.0.0/24 \
				--log-file "/tmp/distcc/${release}-${arch}.log" --user distccd

	[[ -d $build_dir ]] ||
		exit_with_error "Clean Environment is not visible" "$build_dir"

	local t=$build_dir/root/.update-timestamp
	if [[ ! -f ${t} || $((($(date +%s) - $(< "${t}")) / 86400)) -gt 3 ]]; then
		display_alert "Upgrading packages" "$release/$arch" "info"
		systemd-nspawn -a -q -D "${build_dir}" /bin/bash -c "apt-get -q update; apt-get -q -y upgrade; apt-get clean"
		date +%s > "${t}"
		display_alert "Repack a clean Environment archive after upgrading" "${t_name}.tar.xz" "info"
		rm "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		(
			tar -cp --directory="${tmp_dir}/" ${t_name} |
				pv -p -b -r -s "$(du -sb "${tmp_dir}/${t_name}" | cut -f1)" |
				pixz -4 > "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		)
		# DEBUG
		cat $build_dir/etc/apt/sources.list >>"$DEST/${LOG_SUBPATH}/${t_name}.log"
	fi

	local config_for_packages=""
	local src_dir

	display_alert "Final config:" "$config_for_packages" "ext"
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
			display_alert "Нет конфигурации для пакета" "${package_name}" "wrn"
			config_for_packages="src"
			src_dir="${USERPATCHES_PATH}"/packages/deb-build/${package_name}
			mkdir -p $src_dir
		fi

		unset package_repo package_ref package_builddeps \
			  package_install_chroot package_install_target \
			  package_upstream_version needs_building pkg_target_dir \
			  package_component "package_builddeps_${release}"

		if [ -f $config_for_packages ]; then
			source "${config_for_packages}"
		fi

		# check build condition
		if [[ $(type -t package_checkbuild) == function ]] && ! package_checkbuild; then
			display_alert "Skipping building $package_name for" "$release/$arch"
			continue
		fi

		local pkg_target_dir="${DEB_STORAGE}/${release}/${package_name}"
		mkdir -p "${pkg_target_dir}"
		local src_cache_dir="${SRC}"/cache/sources/$package_name
		mkdir -p "${src_cache_dir}"

		# check if needs building
		echo "$(find "${pkg_target_dir}/" -name "${package_name}"_'*'_"$arch".deb)" >&2
		if [[ -f $(find "${pkg_target_dir}/" -name "${package_name}"_'*'_"$arch".deb) ]]; then
			display_alert "Packages are up to date" "$package_name $release/$arch" "info"
			continue
		fi

		# Delete the environment if there was a build in it.
		# And unpack the clean environment again.
		if [[ -f "${build_dir}"/root/build.sh ]] && [[ -d $tmp_dir ]]; then
			rm -rf $tmp_dir
			local tmp_dir=$(mktemp -d "${SRC}"/.tmp/build-XXXXX)
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

		eval systemd-nspawn -a -q \
				--capability=CAP_MKNOD -D "${build_dir}" \
				--tmpfs=/root/build \
				--tmpfs=/tmp:mode=777 \
				--bind-ro "$src_dir"/:/root/overlay \
				--bind-ro "${SRC}"/cache/sources/:/root/sources \
				/bin/bash -c "/root/build.sh" \
				${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/buildpkg.log'} 2>&1 \
				';EVALPIPE=(${PIPESTATUS[@]})'

		if [[ ${EVALPIPE[0]} -ne 0 ]]; then
			failed+=("$package_name:$release/$arch")
			mv "${build_dir}"/root/build.sh "$DEST/${LOG_SUBPATH}/"
		else
			built_ok+=("$package_name:$release/$arch")
			mv "${build_dir}"/root/"$package_name"*"$arch"* "${pkg_target_dir}" 2> /dev/null
		fi

		mv "${build_dir}"/root/*.log "$DEST/${LOG_SUBPATH}/"

		te=$(date +%s)
		display_alert "Build time $package_name " " $(($te - $ts)) sec." "info"
	done

	# Delete a temporary directory
	if [ -d $tmp_dir ]; then rm -rf $tmp_dir; fi
	# cleanup for distcc
	kill $(< /var/run/distcc/${release}-${arch}.pid)

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
	local dst_dir="$2"

	if [ -f $src_dir/debian/watch ]; then

		for n in $(
			cd $src_dir; uscan -v | awk '$1 ~ /^version|^package/{print $1 $2 $3}'
			)
		do
			eval "local $n"
		done
		# DEBUG
		echo "package=:$package" >&2
		echo "version=:$version" >&2
	fi

	local tarball=$(find ${dst_dir}/ -name ${package}_${version}.orig.tar'*')
	if [ "$tarball" == "" ]; then
		$(cd $src_dir; uscan --download-current-version --destdir "$dst_dir")
	else
		echo -e "Tarball exist:\n$tarball"
	fi

} # apt-cache show devscripts


# create build script
create_build_script() {
	cat <<-EOF > "${build_dir}"/root/build.sh
	#!/bin/bash
	export PATH="/usr/lib/ccache:\$PATH"
	export HOME="/root"
	export DEBIAN_FRONTEND="noninteractive"
	export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
	export CCACHE_TEMPDIR="/tmp"
	# distcc is disabled to prevent compilation issues due
	# to different host and cross toolchain configurations
	#export CCACHE_PREFIX="distcc"
	# uncomment for debug
	#export CCACHE_RECACHE="true"
	#export CCACHE_DISABLE="true"
	export DISTCC_HOSTS="$distcc_bindaddr"
	export DEBFULLNAME="$MAINTAINER"
	export DEBEMAIL="$MAINTAINERMAIL"
	$(declare -f display_alert)
	$(declare -f check_debian_build_version)

	LOG_OUTPUT_FILE=$LOG_OUTPUT_FILE
	$(declare -f install_pkg_deb)

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
