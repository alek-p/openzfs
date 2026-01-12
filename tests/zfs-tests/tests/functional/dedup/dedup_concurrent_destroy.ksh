#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0

#
# Copyright (c) 2024, Klara Inc.
#

# DESCRIPTION:
#	Verify that concurrent access to DDT stats during DDT destruction
#	(e.g. zpool status -D running while unique/duplicate/empty transitions occur)
#	does not cause a panic or deadlock.
#
# STRATEGY:
#	1. Create a pool with dedup=on.
#	2. Start a background loop running 'zpool status -D'.
#	3. In a loop:
#	   a. Create a file (DDT entry unique).
#	   b. Copy it (DDT entry duplicate).
#	   c. Delete copy (DDT entry unique).
#	   d. Delete original (DDT entry removed -> ZAP destroyed if empty).
#	4. Verify no panics and background loop keeps running.
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "both"

log_assert "Verify DDT ZAP destruction doesn't race with readers"

POOL="dedup_race_pool"
MOUNTDIR="$TEST_BASE_DIR/dedup_race_mount"
VDEV="$TEST_BASE_DIR/vdevfile.race.$$"

function cleanup
{
	if [[ -n "$bg_pid" ]]; then
		kill $bg_pid 2>/dev/null
		wait $bg_pid 2>/dev/null
	fi
	
	if poolexists $POOL ; then
		destroy_pool $POOL
	fi
	log_must rm -f $VDEV
}

log_onexit cleanup

log_must truncate -s 512M $VDEV
log_must zpool create -f -O xattr=sa -m $MOUNTDIR $POOL $VDEV
log_must zfs set compression=off dedup=on $POOL

# Background reader
(
	while true; do
		zpool status -D $POOL > /dev/null 2>&1
		sleep 0.1
	done
) &
bg_pid=$!

# Foreground writer toggling DDT objects
typeset -i i=0
while (( i < 50 )); do
	# Create unique entries (UNIQUE class)
	log_must dd if=/dev/urandom of=$MOUNTDIR/file bs=128k count=1
	log_must sync
	
	# Create duplicate entries (DUPLICATE class)
	log_must cp $MOUNTDIR/file $MOUNTDIR/copy
	log_must sync
	
	# Destroy copy (DUPLICATE -> UNIQUE)
	log_must rm $MOUNTDIR/copy
	log_must sync
	
	# Destroy original (UNIQUE -> Empty)
	log_must rm $MOUNTDIR/file
	log_must sync
	
	((i = i + 1))
done

kill $bg_pid
wait $bg_pid

log_pass "DDT ZAP destruction race test passed"
