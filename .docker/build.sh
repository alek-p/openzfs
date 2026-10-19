#!/usr/bin/env bash
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

# Build OpenZFS in a container, on the distribution of your choice.
#
#   .docker/build.sh                        # ubuntu:24.04, the default
#   .docker/build.sh -i fedora              # fedora:latest
#   .docker/build.sh -i centos-stream9
#   .docker/build.sh -i alpine:3.21 shell   # poke around instead of building
#   .docker/build.sh -i ubuntu -i fedora42  # same tree, both distributions
#   .docker/build.sh --list                 # known short names
#
# Any image reference docker understands works too; the short names below
# are just conveniences.  install-deps.sh probes the package manager at
# image build time, so unlisted distributions generally work as well.
#
# The source tree is bind mounted into the container and each image gets its
# own out-of-tree build directory under build/<image>, so switching
# distributions does not force a rebuild from scratch.

set -eu

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_dir="$src/.docker"
container_src=/zfs

DEFAULT_IMAGE=ubuntu:24.04

# Short name -> image reference.  Kept in one place so --list and the
# resolver cannot disagree.  (A case statement rather than an associative
# array: macOS still ships bash 3.2.)
known_images() {
	cat <<-'EOF'
	ubuntu          ubuntu:24.04
	ubuntu2404      ubuntu:24.04
	ubuntu2204      ubuntu:22.04
	debian          debian:12
	debian13        debian:13
	fedora          fedora:latest
	fedora42        fedora:42
	fedora41        fedora:41
	centos-stream9  quay.io/centos/centos:stream9
	centos-stream10 quay.io/centos/centos:stream10
	almalinux8      almalinux:8
	almalinux9      almalinux:9
	almalinux10     almalinux:10
	rockylinux9     rockylinux:9
	alpine          alpine:latest
	archlinux       archlinux:latest
	tumbleweed      opensuse/tumbleweed:latest
	leap            opensuse/leap:latest
	EOF
}

resolve_image() {
	local name="$1" short ref
	while read -r short ref ; do
		if [ "$name" = "$short" ] ; then
			echo "$ref"
			return
		fi
	done < <(known_images)
	# Not a short name: assume it is already an image reference.
	echo "$name"
}

usage() {
	sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<-'EOF'
	Options:
	  -i, --image IMAGE       base image or short name (repeatable)
	  -e, --extra-packages P  extra packages to install in the image
	  -j, --jobs N            make -j level (default: container nproc)
	      --configure-args A  extra configure flags
	      --kernel            build kernel modules too, against the host's
	                          running kernel: mounts /lib/modules and
	                          /usr/src read-only and implies --privileged.
	                          Linux hosts only.
	      --privileged        run with --privileged and the host /dev, so the
	                          container can load modules and use loopback
	                          devices.  Required for the test suite.
	      --no-cache          docker build --no-cache
	      --build-only        build the image(s), do not run anything
	      --distclean-src     'make distclean' the source tree, then exit
	      --pull              always re-pull the base image
	  -l, --list              list known short names and exit
	  -h, --help              this message

	Remaining arguments are the container command: build (default), configure,
	make, check, modules, test, distclean or shell.  Anything else is exec'd
	directly, e.g. '... -- ./build/ubuntu-24.04/ztest -V'.

	See .docker/README.md for the test suite workflow.
	EOF
}

images=()
extra_packages=""
configure_args=""
jobs=""
no_cache=""
pull=""
build_only=""
distclean_src=""
privileged=""
kernel=""

while [ $# -gt 0 ] ; do
	case "$1" in
	-i|--image)           images+=("$2") ; shift 2 ;;
	-e|--extra-packages)  extra_packages="$2" ; shift 2 ;;
	-j|--jobs)            jobs="$2" ; shift 2 ;;
	--configure-args)     configure_args="$2" ; shift 2 ;;
	--privileged)         privileged=1 ; shift ;;
	--kernel)             kernel=1 ; privileged=1 ; shift ;;
	--no-cache)           no_cache=1 ; shift ;;
	--pull)               pull=1 ; shift ;;
	--build-only)         build_only=1 ; shift ;;
	--distclean-src)      distclean_src=1 ; shift ;;
	-l|--list)            known_images ; exit 0 ;;
	-h|--help)            usage ; exit 0 ;;
	--)                   shift ; break ;;
	-*)
		echo "Unknown option: $1" >&2
		echo "Try --help." >&2
		exit 1
		;;
	*)                    break ;;
	esac
done

[ ${#images[@]} -gt 0 ] || images=("$DEFAULT_IMAGE")

command -v docker >/dev/null 2>&1 || {
	echo "docker not found on PATH" >&2
	exit 1
}

# Module builds have to compile against the kernel the container will
# actually run on, which is the host's.  That only lines up on a Linux host
# with its kernel headers installed; on macOS or Windows the "host" is a
# hypervisor VM whose headers are not available.
if [ -n "$kernel" ] ; then
	if [ "$(uname -s)" != "Linux" ] ; then
		cat >&2 <<-EOF
		ERROR: --kernel needs a Linux host (this is $(uname -s)).

		Docker Desktop runs containers inside a Linux VM whose kernel
		headers are not available, so modules built there cannot be
		loaded.  Use a Linux host, or a VM you control -- see
		.github/workflows/scripts/qemu-*.sh for the CI approach.
		EOF
		exit 1
	fi
	if [ ! -d "/lib/modules/$(uname -r)/build" ] ; then
		cat >&2 <<-EOF
		ERROR: /lib/modules/$(uname -r)/build does not exist.

		Install the kernel headers for the running kernel, e.g.
		  apt-get install linux-headers-$(uname -r)      # Debian/Ubuntu
		  dnf install kernel-devel-$(uname -r)           # Fedora/RHEL
		EOF
		exit 1
	fi
fi

# Interactive only when we actually have a terminal, so this stays usable
# from a script or CI job.  Written as a plain string because macOS bash 3.2
# cannot expand an empty array under 'set -u'.
tty_args=""
if [ -t 0 ] && [ -t 1 ] ; then
	tty_args="-it"
fi

for image in "${images[@]}" ; do
	base="$(resolve_image "$image")"
	slug="${base//[:\/]/-}"
	tag="openzfs-build:$slug"

	echo "=== $base  ->  $tag"

	build_args=(--build-arg "BASE_IMAGE=$base")
	[ -n "$extra_packages" ] &&
	    build_args+=(--build-arg "EXTRA_PACKAGES=$extra_packages")
	[ -n "$no_cache" ] && build_args+=(--no-cache)
	[ -n "$pull" ] && build_args+=(--pull)

	docker build -f "$docker_dir/Dockerfile" -t "$tag" \
	    "${build_args[@]}" "$docker_dir"

	[ -n "$build_only" ] && continue

	run_args=(--rm -v "$src:$container_src")
	[ -n "$jobs" ] && run_args+=(-e "ZFS_MAKE_JOBS=$jobs")

	if [ -n "$kernel" ] ; then
		# Build against the host's headers rather than anything in the
		# image, so the resulting module matches the kernel the
		# container runs on.  /usr/src too: /lib/modules/*/build is
		# usually a symlink into it.
		run_args+=(-v "/lib/modules:/lib/modules:ro")
		[ -d /usr/src ] && run_args+=(-v "/usr/src:/usr/src:ro")
		: "${configure_args:=--with-config=all}"
	fi

	if [ -n "$privileged" ] ; then
		# The suite needs loopback devices, device mapper and the
		# ability to insmod; all of that needs real device access.
		run_args+=(--privileged -v /dev:/dev)
	fi

	[ -n "$configure_args" ] &&
	    run_args+=(-e "ZFS_CONFIGURE_ARGS=$configure_args")

	if [ -n "$distclean_src" ] ; then
		# Done inside the container so it does not depend on the host
		# having a configured tree or the right autotools.
		docker run "${run_args[@]}" "$tag" \
		    sh -c "cd $container_src && make distclean || true"
		continue
	fi

	# shellcheck disable=SC2086  # tty_args is intentionally word split
	docker run $tty_args "${run_args[@]}" "$tag" "$@"
done
