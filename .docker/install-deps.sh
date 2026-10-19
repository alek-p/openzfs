#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.

# Install the OpenZFS build dependencies on whatever distribution we happen
# to be running on.
#
# Written in POSIX sh on purpose: some base images (alpine) have no bash
# until this script installs one.
#
# EXTRA_PACKAGES is an optional space separated list of additional packages,
# useful for kernel headers or anything else a particular image needs.

set -eu

EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

# Install a package list, tolerating names that do not exist on this
# distribution.  Package naming drifts between releases (and between a
# distribution and its derivatives), so a single missing name should not
# fail the whole image build.  Try the fast bulk install first, and only
# fall back to the slow one-at-a-time path if that fails.
install_tolerant() {
	if pkg_install "$@" ; then
		return 0
	fi

	echo "Bulk install failed, retrying package by package"
	skipped=""
	for pkg in "$@" ; do
		if ! pkg_install "$pkg" ; then
			skipped="$skipped $pkg"
		fi
	done
	if [ -n "$skipped" ] ; then
		echo "WARNING: packages unavailable on this image:$skipped"
	fi
}

# One at a time, so a kernel package that doesn't exist for this uname
# does not force the rest of the list down the slow retry path.
install_optional() {
	for pkg in "$@" ; do
		if ! pkg_install "$pkg" ; then
			echo "WARNING: package unavailable on this image: $pkg"
		fi
	done
}

# Packages every distribution names the same way, or close enough that the
# per-distribution lists below only have to carry the differences.
#
# Kernel packages CI names after the running kernel (linux-headers-$(uname -r)
# and the rest) are installed too.  They exist only when the distro packages
# that kernel.  Docker Desktop's linuxkit kernel is not one of them, so those
# packages are skipped there; linux-headers-generic (or kernel-devel) is still
# installed.  A module loads only into the kernel it was built for, so
# build.sh --kernel keeps mounting the host's headers when you actually test.

debian_deps() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -y
	pkg_install() { apt-get install -y --no-install-recommends "$@" ; }

	install_tolerant \
	    acl alien attr autoconf automake bc build-essential cpio curl \
	    dkms fakeroot fio gawk gdb git jq ksh libacl1-dev libaio-dev \
	    libattr1-dev libblkid-dev libcurl4-openssl-dev libdevmapper-dev \
	    libelf-dev libffi-dev libmount-dev libpam0g-dev libselinux1-dev \
	    libssl-dev libtirpc-dev libtool libtool-bin libudev-dev \
	    libunwind-dev lsscsi parted pkg-config python3 python3-cffi \
	    python3-dev python3-packaging python3-setuptools rpm2cpio rsync \
	    strace sysstat uuid-dev wget xxhash zlib1g-dev

	# The rest of CI's guest install, kernel packages included.
	# devscripts is just for checkbashisms.
	install_tolerant \
	    cppcheck cryptsetup dbench devscripts dh-python dh-sequence-dkms \
	    flake8 gdebi isc-dhcp-client lcov linux-headers-generic \
	    linux-tools-common mandoc nfs-kernel-server pamtester pax-utils \
	    python3-all-dev python3-distlib python3-sphinx qemu-guest-agent \
	    rng-tools samba shellcheck watchdog xfslibs-dev

	install_optional \
	    "linux-headers-$(uname -r)" \
	    "linux-modules-extra-$(uname -r)" \
	    linux-perf

	rm -rf /var/lib/apt/lists/*
}

rhel_deps() {
	dnf=dnf
	command -v dnf >/dev/null 2>&1 || dnf=yum
	pkg_install() { $dnf install -y "$@" ; }

	# EPEL carries several of the packages below (ksh, lsscsi, ...) and
	# the CRB/PowerTools repository carries the -devel packages.  Neither
	# exists on Fedora, where everything is in the main repositories, so
	# all of this is best effort.
	$dnf install -y epel-release || true
	$dnf config-manager -y --set-enabled crb ||
	    $dnf config-manager -y --set-enabled powertools || true

	# Alma/CentOS call it "Development Tools", Fedora "development-tools".
	$dnf group install -y "Development Tools" ||
	    $dnf group install -y development-tools || true

	install_tolerant \
	    acl attr autoconf automake bc cpio curl device-mapper-devel \
	    elfutils-libelf-devel fio gawk gdb git jq kernel-rpm-macros ksh \
	    libacl-devel libaio-devel libattr-devel libblkid-devel \
	    libcurl-devel libffi-devel libmount-devel libselinux-devel \
	    libtirpc-devel libtool libudev-devel libunwind-devel \
	    libuuid-devel lsscsi ncompress openssl-devel pam-devel parted \
	    pkgconf-pkg-config python3 python3-cffi python3-devel \
	    python3-packaging python3-setuptools rpm-build rsync strace \
	    sysstat wget xxhash zlib-devel

	install_tolerant \
	    ShellCheck bzip2 cppcheck cryptsetup dbench \
	    devscripts-checkbashisms dkms kernel-abi-stablelists \
	    kernel-abi-whitelists kernel-devel libargon2-devel libnl3-devel \
	    libyaml-devel mandoc mdadm nfs-utils pamtester pax-utils perf \
	    python3-flake8 qemu-guest-agent rng-tools rpcgen samba \
	    util-linux-script watchdog xfsprogs-devel

	install_optional "kernel-devel-$(uname -r)"

	$dnf clean all
}

suse_deps() {
	zypper --non-interactive refresh
	pkg_install() { zypper --non-interactive install -y "$@" ; }

	zypper --non-interactive install -y -t pattern devel_C_C++ || true

	install_tolerant \
	    acl attr autoconf automake bc cpio curl device-mapper-devel fio \
	    gawk gcc gdb git jq ksh libacl-devel libaio-devel libattr-devel \
	    libblkid-devel libcurl-devel libelf-devel libffi-devel \
	    libmount-devel libopenssl-devel libselinux-devel libtirpc-devel \
	    libtool libuuid-devel libunwind-devel lsscsi make ncompress \
	    pam-devel parted pkg-config python3 python3-cffi python3-devel \
	    python3-packaging python3-setuptools rpm-build rsync strace \
	    sysstat systemd-devel wget xxhash zlib-devel

	# CI has no SUSE package list. These are the same tools the other
	# guests install.
	install_tolerant \
	    ShellCheck checkbashisms cppcheck cryptsetup kernel-default-devel \
	    lcov mandoc nfs-kernel-server pamtester pax-utils python3-flake8 \
	    qemu-guest-agent rng-tools samba watchdog

	zypper clean --all
}

arch_deps() {
	pacman -Syu --noconfirm
	pkg_install() { pacman -S --noconfirm --needed "$@" ; }

	install_tolerant \
	    acl attr base-devel bc cpio curl device-mapper elfutils fakeroot \
	    fio gawk gdb git jq ksh libaio libffi libtirpc libtool libunwind \
	    lsscsi openssl parted pkgconf python python-cffi python-packaging \
	    python-setuptools rsync strace sysstat systemd-libs util-linux \
	    util-linux-libs wget xxhash zlib

	install_tolerant \
	    checkbashisms cppcheck cryptsetup dhclient dkms inetutils less \
	    linux linux-headers mandoc nfs-utils pax pax-utils perf \
	    python-flake8 qemu-guest-agent rng-tools samba shellcheck

	pacman -Scc --noconfirm || true
}

alpine_deps() {
	apk update
	pkg_install() { apk add --no-cache "$@" ; }

	# musl needs libtirpc and a few explicit -dev packages that glibc
	# distributions fold into their base development groups.
	install_tolerant \
	    acl acl-dev alpine-sdk attr attr-dev autoconf automake bash bc \
	    build-base coreutils cpio curl curl-dev elfutils-dev eudev-dev \
	    findutils fio gawk gdb gettext-dev git grep jq libaio-dev \
	    libffi-dev libtirpc-dev libtool libunwind-dev linux-headers \
	    lsscsi m4 make openssl-dev parted pkgconf py3-cffi py3-packaging \
	    py3-setuptools python3 python3-dev rsync sed strace sysstat \
	    util-linux util-linux-dev wget xxhash zlib-dev

	# scanelf is its own package; pax-utils does not ship the binary.
	install_tolerant \
	    checkbashisms clang cppcheck cryptsetup dhcpcd diffutils eudev \
	    eudev-dev eudev-libs ksh libaio libcap-utils libcurl libunwind \
	    linux-stable linux-stable-dev linux-tools mandoc nfs-utils pax \
	    procps py3-distlib py3-flake8 qemu-guest-agent rng-tools samba \
	    samba-server scanelf shellcheck tzdata words xfsprogs

	# pamtester is in the testing repo on Alpine, which is how CI asks for it.
	pkg_install pamtester@testing || true

	if ! command -v ksh >/dev/null 2>&1 ; then
		# CI builds ksh93 from the 1.0 branch; Alpine has no such package.
		git clone --depth 1 --branch 1.0 https://github.com/ksh93/ksh.git /tmp/ksh
		( cd /tmp/ksh && ./bin/package make && ./bin/package install / )
		rm -rf /tmp/ksh
	fi
}

# Prefer /etc/os-release, but fall back to whichever package manager is on
# PATH so that unlisted derivatives still work.
distro_id=""
if [ -r /etc/os-release ] ; then
	# shellcheck disable=SC1091
	. /etc/os-release
	distro_id="${ID:-} ${ID_LIKE:-}"
fi

echo "Installing OpenZFS build dependencies for: ${distro_id:-unknown}"

case "$distro_id" in
	*debian*|*ubuntu*) deps=debian_deps ;;
	*rhel*|*fedora*|*centos*) deps=rhel_deps ;;
	*suse*) deps=suse_deps ;;
	*arch*) deps=arch_deps ;;
	*alpine*) deps=alpine_deps ;;
	*)
		if command -v apt-get >/dev/null 2>&1 ; then
			deps=debian_deps
		elif command -v dnf >/dev/null 2>&1 ||
		     command -v yum >/dev/null 2>&1 ; then
			deps=rhel_deps
		elif command -v zypper >/dev/null 2>&1 ; then
			deps=suse_deps
		elif command -v pacman >/dev/null 2>&1 ; then
			deps=arch_deps
		elif command -v apk >/dev/null 2>&1 ; then
			deps=alpine_deps
		else
			echo "No supported package manager found" >&2
			exit 1
		fi
		;;
esac

$deps

if [ -n "$EXTRA_PACKAGES" ] ; then
	echo "Installing EXTRA_PACKAGES: $EXTRA_PACKAGES"
	# shellcheck disable=SC2086
	install_tolerant $EXTRA_PACKAGES
fi

echo "Dependencies installed."
