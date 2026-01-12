#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0

#
# Copyright (c) 2016 by Delphix. All rights reserved.
#

. $STF_SUITE/tests/functional/channel_program/channel_common.kshlib

#
# DESCRIPTION:
#       zfs.get_prop should work on bookmarks.

verify_runnable "global"

function cleanup
{
	destroy_dataset $TESTPOOL/$TESTFS@$TESTSNAP -R
}
log_onexit cleanup

# create $TESTSNAP
create_snapshot
log_must zfs bookmark $TESTPOOL/$TESTFS@$TESTSNAP $TESTPOOL/$TESTFS#bm

log_must_program $TESTPOOL $ZCP_ROOT/lua_core/tst.bookmarks.zcp \
    $TESTPOOL $TESTPOOL/$TESTFS $TESTPOOL/$TESTFS@$TESTSNAP \
    $TESTPOOL/$TESTFS#bm

log_pass "zfs.get_prop() on bookmarks works"
