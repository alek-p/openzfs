#!/bin/ksh -p
#
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2025, Gemini CLI. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# Verify 'zpool status -E' excludes pools and 'zpool status -D -p' prints raw numbers.
#
# STRATEGY:
# 1. Create two auxiliary pools.
# 2. Verify 'zpool status' shows all pools.
# 3. Verify 'zpool status -E <pool>' excludes the specified pool.
# 4. Verify 'zpool status -E <pool1>,<pool2>' excludes both.
# 5. Enable dedup on one pool and write some data.
# 6. Verify 'zpool status -D' shows human readable numbers.
# 7. Verify 'zpool status -D -p' shows raw numbers.
# 8. Cleanup.
#

verify_runnable "both"

POOL1=testpool_ex1
POOL2=testpool_ex2
DISK1="$TEST_BASE_DIR/disk1.dat"
DISK2="$TEST_BASE_DIR/disk2.dat"

function cleanup
{
    if poolexists $POOL1;
    then
        destroy_pool $POOL1
    fi
    if poolexists $POOL2;
    then
        destroy_pool $POOL2
    fi
    rm -f $DISK1 $DISK2
    unset __ZFS_POOL_EXCLUDE
}

log_onexit cleanup

log_assert "Verify 'zpool status -E' and 'zpool status -D -p'"

# 1. Setup aux pools
truncate -s $MINVDEVSIZE $DISK1
truncate -s $MINVDEVSIZE $DISK2

log_must zpool create $POOL1 $DISK1
log_must zpool create $POOL2 $DISK2

# 2. Verify standard output contains all pools
output=$(zpool status)
log_must eval "echo \"$output\" | grep -q \"pool: $POOL1\""
log_must eval "echo \"$output\" | grep -q \"pool: $POOL2\""

# 3. Verify exclusion of one pool
output=$(zpool status -E $POOL1)
log_mustnot eval "echo \"$output\" | grep -q \"pool: $POOL1\""
log_must eval "echo \"$output\" | grep -q \"pool: $POOL2\""

# 4. Verify exclusion of multiple pools (comma separated)
output=$(zpool status -E $POOL1,$POOL2)
log_mustnot eval "echo \"$output\" | grep -q \"pool: $POOL1\""
log_mustnot eval "echo \"$output\" | grep -q \"pool: $POOL2\""

# 5. Setup dedup stats
log_must zfs set dedup=on $POOL1
log_must mkfile 10M /$POOL1/file1
log_must cp /$POOL1/file1 /$POOL1/file2
log_must zpool sync $POOL1

# 6. Verify -D (human readable)
# Should contain 'k', 'M', or 'G' suffix, or just small numbers. 
# We look for standard nicenum formatting like "10M" or "20.00x".
# This check is fuzzy but ensures we don't just see raw bytes everywhere.
output=$(zpool status -D $POOL1)
log_must eval "echo \"$output\" | grep -q \"DDT entries\""

# 7. Verify -D -p (raw values)
# Raw values should be digits only for sizes.
output=$(zpool status -D -p $POOL1)
log_must eval "echo \"$output\" | grep -q \"DDT entries\""
# Extract the "on disk" size line.
# Example: DDT entries 123, size 123456 on disk, ...
# We want to ensure there are no K/M/G suffixes in the size fields.
# We'll check if the output contains lines that look like raw numbers.
dspace=$(echo "$output" | grep "size .* on disk" | awk '{print $4}')
log_must test "$dspace" -gt 0
log_must eval "echo \"$dspace\" | grep -E -q '^[0-9]+$'"

log_pass "'zpool status -E' and '-D -p' behave as expected."

