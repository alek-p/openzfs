# Fix Plan for OpenZFS Issues

## Overview
This plan addresses three related kernel panics occurring during `txg_sync` in OpenZFS, as described in Issue #15 and related tickets.

## Issues & Fixes

### 1. spa_sync_time_logger Panic (Issue #18112)
**Problem:** `spa_sync_time_logger` panics with `VERIFY3U(tx->tx_txg, <=, spa_final_dirty_txg(os->os_spa))` when the current txg exceeds the final dirty txg.
**File:** `module/zfs/spa.c`
**Fix:** Add a check at the beginning of `spa_sync_time_logger` to return early if `txg > spa_final_dirty_txg(spa)`.

### 2. zfs_range_tree_add_impl Panic (Issue #18111)
**Problem:** `zfs_range_tree_add_impl` panics (via `zfs_panic_recover`) when adding a segment that overlaps with an existing one in a gap-0 tree (e.g., metaslab frees).
**File:** `module/zfs/range_tree.c`
**Fix:** Replace `zfs_panic_recover` with `zfs_dbgmsg` (or similar logging) and return. This prevents the crash while acknowledging the inconsistency.

### 3. vdev_indirect_mark_obsolete Panic (Issue #18098)
**Problem:** `vdev_indirect_mark_obsolete` panics with `VERIFY(vdev_indirect_mapping_entry_for_offset(...) != NULL)` when an offset is not found in the mapping.
**File:** `module/zfs/vdev_indirect.c`
**Fix:** Store the result of `vdev_indirect_mapping_entry_for_offset` in a variable. Check if it is NULL. If so, log a debug message and return, skipping the obsolete marking.

## Testing Strategy
*   Since these are kernel panics triggered by specific race conditions or inconsistent states, reproducing them deterministically in a short timeframe is difficult.
*   I will attempt to write a test case `cmd/ztest.c` or a shell script in `tests/` if applicable, but given the nature of these bugs (race/corruption), code analysis and defensive programming are the primary verification methods.
*   I will verify that the code compiles.

## Steps
1.  Modify `module/zfs/spa.c`.
2.  Modify `module/zfs/range_tree.c`.
3.  Modify `module/zfs/vdev_indirect.c`.
4.  Compile/Verify.
5.  Commit.