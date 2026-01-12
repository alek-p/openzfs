#! /bin/ksh -p
#
# This test attempts to verify that the system does not panic during
# heavy transaction group syncing operations, addressing issues #18112, #18111, #18098.
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

function cleanup
{
	if poolexists $TESTPOOL; then
		destroy_pool $TESTPOOL
	fi
}

log_onexit cleanup

log_assert "Verify txg_sync does not panic under load with async destroys"

# Create a pool
log_must default_setup_noexit $DISKS

# Generate some load
log_note "Creating datasets and snapshots..."
for i in {1..50}; do
	log_must zfs create $TESTPOOL/fs$i
	log_must zfs snapshot $TESTPOOL/fs$i@snap
done

# Asynchronous destroy
log_note "Destroying datasets asynchronously..."
for i in {1..50}; do
	zfs destroy -r $TESTPOOL/fs$i &
done

wait

log_must zpool scrub $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

log_pass "No panic observed during txg_sync operations"
