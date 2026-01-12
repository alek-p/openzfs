#!/bin/ksh
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#

#
# Copyright (c) 2025 by Alek P. All rights reserved.
#

#
# DESCRIPTION
# Verify no deadlock occurs when accessing .zfs/snapshot while unmounting.
#
# STRATEGY
# 1. Create a dataset and set snapdir=visible.
# 2. In a loop, create a snapshot.
# 3. Start a background process that accesses the snapshot directory (triggering mount).
# 4. Concurrently try to unmount the filesystem or destroy the snapshot.
# 5. Verify that the operations complete and don't hang.
#

. $STF_SUITE/include/libtest.shlib

function cleanup
{
	datasetexists $TESTPOOL/$TESTFS && destroy_dataset $TESTPOOL/$TESTFS -r
}

log_assert "Verify no deadlock when accessing .zfs/snapshot during unmount"
log_onexit cleanup

log_must zfs create $TESTPOOL/$TESTFS
log_must zfs set snapdir=visible $TESTPOOL/$TESTFS

for i in {1..20}; do
    SNAP=$TESTPOOL/$TESTFS@snap$i
    log_must zfs snapshot $SNAP
    
    # Trigger automount in background
    ( ls -l /$TESTPOOL/$TESTFS/.zfs/snapshot/snap$i > /dev/null 2>&1 ) &
    PID_LS=$!
    
    # Give it a tiny moment to start mounting
    sleep 0.1
    
    # Try to unmount concurrently
    # This might fail with EBUSY if mount is successful, but shouldn't deadlock.
    zfs unmount $TESTPOOL/$TESTFS > /dev/null 2>&1
    
    wait $PID_LS
    
    # Ensure it's mounted back if we unmounted it
    if ! ismounted $TESTPOOL/$TESTFS; then
        log_must zfs mount $TESTPOOL/$TESTFS
    fi
    
    log_must zfs destroy $SNAP
done

log_pass "No deadlock detected"
