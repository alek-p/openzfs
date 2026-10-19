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

# Configure and build OpenZFS out of tree, in a build directory named after
# the base image.  The source tree is expected to be bind mounted at $ZFS_SRC
# so that several images can share one checkout without fighting over the
# generated files.
#
# Usage: zfs-build [COMMAND] [ARGS...]
#
#   build            autogen + configure (if needed) + make    (default)
#   configure        (re-)run configure only
#   make ARGS...     run make in the build directory
#   check            run make check
#   modules          load the freshly built module stack (needs --privileged)
#   test ARGS...     run the ZFS Test Suite (needs --privileged and modules)
#   distclean        remove this image's build directory
#   shell            interactive shell, cwd set to the build directory
#   ANYTHING ELSE    exec'd as-is, so 'docker run ... image ztest -V' works
#
# Environment:
#   ZFS_CONFIGURE_ARGS   extra configure flags (default --with-config=user)
#   ZFS_MAKE_JOBS        -j level (default: nproc)

set -eu

ZFS_SRC="${ZFS_SRC:-/zfs}"
ZFS_BASE_IMAGE="${ZFS_BASE_IMAGE:-unknown}"
ZFS_MAKE_JOBS="${ZFS_MAKE_JOBS:-$(nproc 2>/dev/null || echo 4)}"

# A container's 'uname -r' is the host kernel, so its headers are not in the
# image and a module build would fail (or worse, silently build against the
# wrong kernel).  Userspace only is the useful default here; override with
# ZFS_CONFIGURE_ARGS if you have mounted matching kernel sources in.
ZFS_CONFIGURE_ARGS="${ZFS_CONFIGURE_ARGS:---with-config=user}"

# fedora:42 -> fedora-42, so the build directory is a legal path component.
slug="$(echo "$ZFS_BASE_IMAGE" | tr ':/' '--')"
builddir="$ZFS_SRC/build/$slug"

if [ ! -d "$ZFS_SRC" ] ; then
	echo "ERROR: $ZFS_SRC does not exist." >&2
	echo "Bind mount the OpenZFS source tree there, e.g." >&2
	echo "  docker run --rm -v \"\$PWD:$ZFS_SRC\" IMAGE" >&2
	exit 1
fi

# An in-tree './configure' run leaves a config.status at the top of the
# source tree, and autoconf refuses to configure out of tree while it is
# there.  Say so plainly rather than letting configure fail cryptically.
check_srcdir_clean() {
	if [ -e "$ZFS_SRC/config.status" ] ; then
		cat >&2 <<-EOF
		ERROR: $ZFS_SRC is already configured in tree.

		Out of tree builds cannot coexist with an in-tree configure.
		Clean the source tree first:

		    make distclean        # in $ZFS_SRC, on the host
		    # or: .docker/build.sh --distclean-src

		EOF
		exit 1
	fi
}

run_autogen() {
	# configure is generated, not committed; regenerate it if it is
	# missing or older than its inputs.
	if [ ! -x "$ZFS_SRC/configure" ] ||
	   [ "$ZFS_SRC/configure.ac" -nt "$ZFS_SRC/configure" ] ; then
		echo "==> autogen.sh"
		(cd "$ZFS_SRC" && ./autogen.sh)
	fi
}

run_configure() {
	check_srcdir_clean
	run_autogen
	mkdir -p "$builddir"
	echo "==> configure $ZFS_CONFIGURE_ARGS"
	# shellcheck disable=SC2086
	(cd "$builddir" && "$ZFS_SRC/configure" $ZFS_CONFIGURE_ARGS)
}

# checkstyle's rules assume `make` was run in the source tree. An out-of-tree
# build breaks that in ways that are invisible until the checks run:
#   mancheck looks for scripts/mancheck.sh in the build directory
#   spdxcheck and vcscheck open git paths relative to the current directory
#   cstyle's -path './module/...' exclusions never match an absolute find
#   testscheck uses test -x, which is true for every file on some bind
#     mounts (Docker Desktop) even when the mode is 0644
# Rewrite the generated Makefile in this build directory. The upstream
# rules stay as they are.
patch_oot_checks() {
	local mk="$builddir/Makefile"
	[ -f "$mk" ] || return 0
	grep -q 'zfs-build oot checkstyle' "$mk" && return 0

	python3 - "$mk" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
n = 0
def sub(old, new):
    global text, n
    count = text.count(old)
    if count == 0:
        sys.exit("zfs-build: %r not in %s" % (old, path))
    text = text.replace(old, new)
    n += count
sub("$(mancheck_verbose)scripts/mancheck.sh",
    "$(mancheck_verbose)$(top_srcdir)/scripts/mancheck.sh")
sub("$(AM_V_at)$(top_srcdir)/scripts/spdxcheck.pl",
    "$(AM_V_at)cd $(top_srcdir) && $(top_srcdir)/scripts/spdxcheck.pl")
sub("! -path './", "! -path '$(top_srcdir)/")
sub("filter_executable = -exec test -x '{}' \\; -print",
    "filter_executable = -perm /111 -print")
sub("git rev-parse --git-dir", "git -C $(top_srcdir) rev-parse --git-dir")
sub("git ls-files . --exclude-standard --others",
    "git -C $(top_srcdir) ls-files . --exclude-standard --others")
open(path, "w").write(text)
if not text.endswith("\n"):
    open(path, "a").write("\n")
open(path, "a").write("# zfs-build oot checkstyle\n")
print("zfs-build: adjusted %d checkstyle rules for out-of-tree build" % n)
PY
}

require_configured() {
	[ -e "$builddir/config.status" ] || run_configure
	patch_oot_checks
}

# The test suite and the module loader both find the in-tree binaries through
# the configure-generated scripts/common.sh, which for an out-of-tree build
# lives in the build directory rather than in $ZFS_SRC/scripts.
export_script_common() {
	if [ ! -e "$builddir/scripts/common.sh" ] ; then
		echo "ERROR: $builddir/scripts/common.sh is missing." >&2
		echo "Run a build first." >&2
		exit 1
	fi
	export SCRIPT_COMMON="$builddir/scripts/common.sh"
}

# Loading a module changes the kernel the *host* is running -- there is no
# per-container module namespace.  Fail early and clearly rather than
# emitting a confusing modprobe error.
require_modules_possible() {
	if [ ! -w /sys/module ] && [ ! -w /dev ] ; then
		cat >&2 <<-EOF
		ERROR: this container cannot load kernel modules.

		Run with --privileged (build.sh --privileged), and note that
		the modules must have been built against the running kernel
		$(uname -r).
		EOF
		exit 1
	fi

	# A userspace-only build has no module to load.  Say so specifically,
	# since this is the most common way to get here by mistake.
	if [ ! -e "$builddir/module/zfs/zfs.ko" ] &&
	   [ ! -e "$builddir/module/zfs.ko" ] ; then
		cat >&2 <<-EOF
		ERROR: no built module found under $builddir/module.

		This build is userspace only.  To build modules, configure
		against the running kernel's headers, e.g.

		    build.sh --kernel -- configure

		See .docker/README.md ("Running the test suite").
		EOF
		exit 1
	fi
}

cmd="${1:-build}"
[ $# -gt 0 ] && shift

case "$cmd" in
build)
	require_configured
	echo "==> make -j$ZFS_MAKE_JOBS ($ZFS_BASE_IMAGE)"
	make -C "$builddir" -j"$ZFS_MAKE_JOBS" "$@"
	echo "==> built in $builddir"
	;;
configure)
	ZFS_CONFIGURE_ARGS="$ZFS_CONFIGURE_ARGS $*"
	run_configure
	;;
make)
	require_configured
	make -C "$builddir" -j"$ZFS_MAKE_JOBS" "$@"
	;;
check)
	require_configured
	make -C "$builddir" -j"$ZFS_MAKE_JOBS" check "$@"
	;;
modules)
	require_configured
	export_script_common
	require_modules_possible
	echo "==> installing helper symlinks"
	"$ZFS_SRC/scripts/zfs-helpers.sh" -i
	echo "==> loading module stack"
	"$ZFS_SRC/scripts/zfs.sh" "$@"
	echo "==> loaded; /dev/zfs $([ -e /dev/zfs ] && echo present || echo MISSING)"
	;;
test)
	require_configured
	export_script_common
	# -h is just the usage text; no need for a loaded module stack.
	if [ "${1:-}" = "-h" ] ; then
		exec "$ZFS_SRC/scripts/zfs-tests.sh" -h
	fi
	if [ ! -e /dev/zfs ] ; then
		cat >&2 <<-EOF
		ERROR: /dev/zfs is missing -- the module stack is not loaded.

		Load it first, in this same container:

		    zfs-build modules

		See .docker/README.md ("Running the test suite").
		EOF
		exit 1
	fi
	# The suite insists on being run from a directory it can write to and
	# expects the in-tree layout that SCRIPT_COMMON describes.
	cd "$builddir"
	exec "$ZFS_SRC/scripts/zfs-tests.sh" "$@"
	;;
distclean)
	echo "==> removing $builddir"
	rm -rf "$builddir"
	;;
shell)
	mkdir -p "$builddir"
	cd "$builddir"
	exec "${SHELL:-/bin/bash}" -l
	;;
*)
	exec "$cmd" "$@"
	;;
esac
