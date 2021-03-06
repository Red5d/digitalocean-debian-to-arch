#!/bin/bash

################################################################################
### INSTRUCTIONS AT https://github.com/gh2o/digitalocean-debian-to-arch/     ###
################################################################################

run_from_file() {
	local f t
	for f in /dev/fd/*; do
		[ -h ${f} ] || continue
		[ ${f} -ef "${0}" ] && return
	done
	t=$(mktemp)
	cat >${t}
	if [ "$(head -n 1 ${t})" = '#!/bin/bash' ]; then
		chmod +x ${t}
		exec /bin/bash ${t} "$@" </dev/fd/2
	else
		rm -f ${t}
		echo "Direct execution not supported with this shell ($_)."
		echo "Please try bash instead."
		exit 1
	fi
}

# do not modify the two lines below
[ -h /dev/fd/0 ] && run_from_file
#!/bin/bash

### CONFIGURATION
archlinux_mirror="https://mirrors.kernel.org/archlinux/"
preserve_home_directories=true

if [ -n "${POSIXLY_CORRECT}" ] || [ -z "${BASH_VERSION}" ]; then
	unset POSIXLY_CORRECT
	exec /bin/bash "${0}" "$@"
	exit 1
fi

set -eu
set -o pipefail
shopt -s nullglob
shopt -s dotglob

export LC_ALL=C
export LANG=C
unset LANGUAGE

declare -A dependencies
dependencies[pacman]=x

log() {
	echo "[$(date)]" "$@" >&2
}

clean_archroot() {
	local file
	local prompted=false
	local lsfd
	while read file <&${lsfd}; do
		if [ "${file}" = "installer" ] || [ "${file}" = "packages" ]; then
			continue
		fi
		if ! $prompted; then
			log "Your /archroot directory contains a stale installation or other data."
			log "Remove it?"
			local response
			read -p '(yes or [no]) ' response
			if [ "${response}" = "yes" ]; then
				prompted=true
			else
				break
			fi
		fi
		rm -rf "/archroot/${file}"
	done {lsfd}< <(ls /archroot)
}

install_haveged() {
	if which haveged >/dev/null 2>&1; then
		return
	fi
	log "Creating keys for pacman will be very slow because"
	log "KVM lacks true sources of ramdomness. Install haveged"
	log "to speed it up?"
	local response
	read -p '([yes] or no) ' response
	if [ "${response}" = "yes" ] || [ -z "${response}" ]; then
		apt-get -y install haveged
	fi
}

initialize_coredb() {
	log "Downloading package database ..."
	wget "${archlinux_mirror}/core/os/x86_64/core.db"
	log "Unpacking package database ..."
	mkdir core
	tar -zxf core.db -C core
}

remove_version() {
	echo "${1}" | grep -o '^[A-Za-z0-9_-]*'
}

get_package_directory() {
	local dir pkg
	for dir in core/${1}-*; do
		if [ "$(get_package_value ${dir}/desc NAME)" = "${1}" ]; then
			echo "${dir}"
			return
		fi
	done
	for dir in core/*; do
		while read pkg; do
			pkg=$(remove_version "${pkg}")
			if [ "${pkg}" = "${1}" ]; then
				echo "${dir}"
				return
			fi
		done < <(get_package_array ${dir}/depends PROVIDES)
	done
	log "Package '${1}' not found."
}

get_package_value() {
	local infofile=${1}
	local infokey=${2}
	get_package_array ${infofile} ${infokey} | (
		local value
		read value
		echo "${value}"
	)
}

get_package_array() {
	local infofile=${1}
	local infokey=${2}
	local line
	while read line; do
		if [ "${line}" = "%${infokey}%" ]; then
			while read line; do
				if [ -z "${line}" ]; then
					return
				fi
				echo "${line}"
			done
		fi
	done < ${infofile}
}

calculate_dependencies() {
	log "Calculating dependencies ..."
	local dirty=true
	local pkg dir dep
	while $dirty; do
		dirty=false
		for pkg in "${!dependencies[@]}"; do
			dir=$(get_package_directory $pkg)
			while read line; do
				dep=$(remove_version "${line}")
				if [ -z "${dependencies[$dep]:-}" ]; then
					dependencies[$dep]=x
					dirty=true
				fi
			done < <(get_package_array ${dir}/depends DEPENDS)
		done
	done
}

download_packages() {
	log "Downloading packages ..."
	mkdir -p /archroot/packages
	local pkg dir filename sha256 localfn
	for pkg in "${!dependencies[@]}"; do
		dir=$(get_package_directory ${pkg})
		filename=$(get_package_value ${dir}/desc FILENAME)
		sha256=$(get_package_value ${dir}/desc SHA256SUM)
		localfn=/archroot/packages/${filename}
		if [ -e "${localfn}" ] && ( echo "${sha256}  ${localfn}" | sha256sum -c ); then
			continue
		fi
		wget "${archlinux_mirror}/core/os/x86_64/${filename}" -O "${localfn}"
		if [ -e "${localfn}" ] && ( echo "${sha256}  ${localfn}" | sha256sum -c ); then
			continue
		fi
		log "Couldn't download package '${pkg}'."
		false
	done
}

extract_packages() {
	log "Extracting packages ..."
	local dir filename
	for pkg in "${!dependencies[@]}"; do
		dir=$(get_package_directory ${pkg})
		filename=$(get_package_value ${dir}/desc FILENAME)
		xz -dc /archroot/packages/${filename} | tar -C /archroot -xf -
	done
}

mount_virtuals() {
	log "Mounting virtual filesystems ..."
	mount -t proc proc /archroot/proc
	mount -t sysfs sys /archroot/sys
	mount --bind /dev /archroot/dev
	mount -t devpts pts /archroot/dev/pts
}

prebootstrap_configuration() {
	log "Doing pre-bootstrap configuration ..."
	rmdir /archroot/var/cache/pacman/pkg
	ln -s ../../../packages /archroot/var/cache/pacman/pkg
	chroot /archroot /usr/bin/update-ca-certificates --fresh
}

bootstrap_system() {

	local shouldbootstrap=false isbootstrapped=false
	while ! $isbootstrapped; do
		if $shouldbootstrap; then
			log "Bootstrapping system ..."
			chroot /archroot pacman-key --init
			chroot /archroot pacman-key --populate archlinux
			chroot /archroot pacman -Sy --force --noconfirm base openssh kexec-tools
			isbootstrapped=true
		else
			shouldbootstrap=true
		fi
		# config overwritten by pacman
		rm -f /archroot/etc/resolv.conf.pacorig
		cp /etc/resolv.conf /archroot/etc/resolv.conf
		rm -f /archroot/etc/pacman.d/mirrorlist.pacorig
		echo "Server = ${archlinux_mirror}"'/$repo/os/$arch' \
			>> /archroot/etc/pacman.d/mirrorlist
	done

}

postbootstrap_configuration() {

	log "Doing post-bootstrap configuration ..."

	# set up fstab
	echo "LABEL=DOROOT / ext4 defaults 0 1" >> /archroot/etc/fstab

	# set up shadow
	(
		umask 077
		{
			grep    '^root:' /etc/shadow
			grep -v '^root:' /archroot/etc/shadow
		} > /archroot/etc/shadow.new
		cat /archroot/etc/shadow.new > /archroot/etc/shadow
		rm /archroot/etc/shadow.new
	)

	# set up network
	local grepfd
	local ipaddr netmask gateway prefixlen=24
	local eni=/etc/network/interfaces
	exec {grepfd}< <(
		grep -m 1 -o 'address [0-9.]\+' ${eni}
		grep -m 1 -o 'netmask [0-9.]\+' ${eni}
		grep -m 1 -o 'gateway [0-9.]\+' ${eni}
	)
	read ignored ipaddr <&${grepfd}
	read ignored netmask <&${grepfd}
	read ignored gateway <&${grepfd}
	exec {grepfd}<&-
	case ${netmask} in
		255.255.255.0)
			prefixlen=24
			;;
		255.255.240.0)
			prefixlen=20
			;;
		255.255.0.0)
			prefixlen=16
			;;
	esac
	cat > /archroot/etc/systemd/network/internet.network <<EOF
[Match]
Name=eth0

[Network]
Address=${ipaddr}/${prefixlen}
Gateway=${gateway}
DNS=8.8.8.8
DNS=8.8.4.4
EOF

	# copy over ssh keys
	cp -p /etc/ssh/ssh_*_key{,.pub} /archroot/etc/ssh/

	# optionally preserve home directories
	if ${preserve_home_directories}; then
		rm -rf /archroot/{home,root}
		cp -al /{home,root} /archroot/
	fi

	# enable services
	chroot /archroot systemctl enable systemd-networkd
	chroot /archroot systemctl enable sshd

	# install services
	local unitdir=/archroot/etc/systemd/system

	mkdir -p ${unitdir}/basic.target.wants
	ln -s ../installer-cleanup.service ${unitdir}/basic.target.wants/
	cat > ${unitdir}/installer-cleanup.service <<EOF
[Unit]
Description=Post-install cleanup
ConditionPathExists=/installer/script.sh

[Service]
Type=oneshot
ExecStart=/installer/script.sh
EOF

	mkdir -p ${unitdir}/sysinit.target.wants
	ln -s ../arch-kernel.service ${unitdir}/sysinit.target.wants
	cat > ${unitdir}/arch-kernel.service <<EOF
[Unit]
Description=Reboots into arch kernel
ConditionKernelCommandLine=!archkernel
DefaultDependencies=no
Before=local-fs-pre.target systemd-remount-fs.service

[Service]
Type=oneshot
ExecStart=/sbin/kexec /boot/vmlinuz-linux --initrd=/boot/initramfs-linux.img --reuse-cmdline --command-line=archkernel
EOF

}

error_occurred() {
	log "Error occurred. Exiting."
}

exit_cleanup() {
	log "Cleaning up ..."
	set +e
	umount /archroot/dev/pts
	umount /archroot/dev
	umount /archroot/sys
	umount /archroot/proc
}

installer_main() {

	if [ "${EUID}" -ne 0 ] || [ "${UID}" -ne 0 ]; then
		log "Script must be run as root. Exiting."
		exit 1
	fi

	if ! grep -q '^7\.' /etc/debian_version; then
		log "This script only supports Debian 7.x. Exiting."
		exit 1
	fi

	if [ "$(uname -m)" != "x86_64" ]; then
		log "This script only targets 64-bit machines. Exiting."
		exit 1
	fi

	trap error_occurred ERR
	trap exit_cleanup EXIT

	log "Ensuring correct permissions ..."
	chmod 0700 "${script_path}"

	rm -rf /archroot/installer
	mkdir -p /archroot/installer
	cd /archroot/installer

	clean_archroot
	install_haveged

	initialize_coredb
	calculate_dependencies
	download_packages
	extract_packages

	mount_virtuals
	prebootstrap_configuration
	bootstrap_system
	postbootstrap_configuration

	# prepare for transtiory_main
	mv /sbin/init /sbin/init.original
	cp "${script_path}" /sbin/init
	reboot

}

transitory_main() {

	if [ "${script_path}" = "/sbin/init" ]; then
		# save script
		mount -o remount,rw /
		cp "${script_path}" /archroot/installer/script.sh
		# restore init in case anything goes wrong
		rm /sbin/init
		mv /sbin/init.original /sbin/init
		# unmount other filesystems
		if ! [ -e /proc/mounts ]; then
			mount -t proc proc /proc
		fi
		local device mountpoint fstype ignored
		while IFS=" " read device mountpoint fstype ignored; do
			if [ "${device}" == "${device/\//}" ] && [ "${fstype}" != "rootfs" ]; then
				umount -l "${mountpoint}"
			fi
		done < <(tac /proc/mounts)
		# mount real root
		mkdir /archroot/realroot
		mount --bind / /archroot/realroot
		# chroot into archroot
		exec chroot /archroot /installer/script.sh
	elif [ "${script_path}" = "/installer/script.sh" ]; then
		# now in archroot
		local oldroot=/realroot/archroot/oldroot
		mkdir ${oldroot}
		# move old files into oldroot
		log "Backing up old root ..."
		local entry
		for entry in /realroot/*; do
			if [ "${entry}" != "/realroot/archroot" ]; then
				mv "${entry}" ${oldroot}
			fi
		done
		# hardlink files into realroot
		log "Populating new root ..."
		cd /
		mv ${oldroot} /realroot
		for entry in /realroot/archroot/*; do
			if [ "${entry}" != "/realroot/archroot/realroot" ]; then
				cp -al "${entry}" /realroot
			fi
		done
		# done!
		log "Rebooting ..."
		mount -t proc proc /proc
		mount -o remount,ro /realroot
		sync
		umount /proc
		reboot -f
	else
		log "Unknown state! You're own your own."
		exec /bin/bash
	fi

}

postinstall_main() {

	# remove cleanup service
	local unitdir=/etc/systemd/system
	rm -f ${unitdir}/installer-cleanup.service
	rm -f ${unitdir}/basic.target.wants/installer-cleanup.service

	# cleanup filesystem
	rm -f /var/cache/pacman/pkg
	mv /packages /var/cache/pacman/pkg
	rm -f /.INSTALL /.MTREE /.PKGINFO
	rm -rf /archroot
	rm -rf /installer

}

canonicalize_path() {
	local basename="$(basename "${1}")"
	local dirname="$(dirname "${1}")"
	(
		cd "${dirname}"
		echo "$(pwd -P)/${basename}"
	)
}

script_path="$(canonicalize_path "${0}")"
if [ $$ -eq 1 ]; then
	transitory_main "$@"
elif [ "${script_path}" = "/sbin/init" ]; then
	exec /sbin/init.original "$@"
elif [ "${script_path}" = "/installer/script.sh" ]; then
	postinstall_main "$@"
else
	installer_main "$@"
fi
