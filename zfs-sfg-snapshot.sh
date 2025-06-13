#!/usr/bin/env bash

# ==============================================================================
# ZFS Son-Father-Grandfather (SFG) Snapshot and Pruning Script for TrueNAS
#
# Creates a new daily snapshot and then prunes old snapshots based on a
# configurable retention policy.
#
# USAGE:
# ./zfs-sfg-snapshot.sh <zfs_dataset>
# ./zfs-sfg-snapshot.sh --dry-run <zfs_dataset>
#
# EXAMPLE:
# ./zfs-sfg-snapshot.sh tank/mydata
#
# v1.1 - Added 'touch' for the keep-list file to prevent errors on first run.
# ==============================================================================

# --- Configuration: Retention Policy ---
# Adjust these values to change the retention policy.
KEEP_DAILY=14
KEEP_MONTHLY=3
KEEP_QUARTERLY=4 # 12 months = 4 quarters
KEEP_YEARLY=3
# --- End Configuration ---

# --- Script Logic ---

# Set a trap to ensure we clean up our temp files on exit.
trap 'rm -f /tmp/zfs_sfg_snaps_all_$$ /tmp/zfs_sfg_snaps_keep_$$ /tmp/all_sorted /tmp/keep_sorted' EXIT

# Check for --dry-run flag
DRY_RUN=0
if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
    shift # Removes --dry-run from the arguments, leaving the dataset
    echo "--- DRY RUN MODE: No snapshots will be created or destroyed. ---"
fi

# Check for required dataset argument
DATASET="$1"
if [ -z "$DATASET" ]; then
    echo "ERROR: No ZFS dataset specified." >&2
    echo "USAGE: $0 [--dry-run] <zfs_dataset>" >&2
    exit 1
fi

# Verify that the dataset actually exists
if ! zfs list -H -o name "$DATASET" >/dev/null 2>&1; then
    echo "ERROR: ZFS dataset '$DATASET' does not exist." >&2
    exit 1
fi

# --- 1. Create Today's Snapshot ---

SNAP_NAME="autosnap_$(date +%Y-%m-%d_%H%M%S)"
FULL_SNAP_NAME="$DATASET@$SNAP_NAME"

echo "Creating snapshot: $FULL_SNAP_NAME"
if [ "$DRY_RUN" -eq 0 ]; then
    zfs snapshot -r "$FULL_SNAP_NAME"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create snapshot $FULL_SNAP_NAME" >&2
        exit 1
    fi
else
    echo "DRY-RUN: Would have run 'zfs snapshot -r \"$FULL_SNAP_NAME\"'"
fi

# --- 2. Prune Old Snapshots ---

echo "Pruning snapshots for $DATASET..."

# Get a list of all relevant snapshots for this dataset, sorted oldest to newest
# -H: no header
# -r: recursive
# -t snapshot: only list snapshots
# -o name: only show the name
# -s creation: sort by creation date
zfs list -H -r -t snapshot -o name -s creation "$DATASET" | grep "@autosnap_" > /tmp/zfs_sfg_snaps_all_$$

# Use associative arrays to track which periods we've already kept a snapshot for
declare -A kept_daily
declare -A kept_monthly
declare -A kept_quarterly
declare -A kept_yearly

# Read the list of all snapshots from newest to oldest to make finding the "last N" easier
# tac reverses the file content (so we go from newest to oldest)
tac /tmp/zfs_sfg_snaps_all_$$ | while read -r snap; do
    # Extract date parts from snapshot name (e.g., tank/data@autosnap_2023-10-27_153000)
    snap_date=$(echo "$snap" | grep -o -E '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    if [ -z "$snap_date" ]; then continue; fi

    year=$(echo "$snap_date" | cut -d- -f1)
    month=$(echo "$snap_date" | cut -d- -f2)
    day=$(echo "$snap_date" | cut -d- -f3)
    quarter=$(( (10#$month - 1) / 3 + 1 )) # Determine quarter (1-4)

    # Convert snapshot date to seconds since epoch for age comparison
    snap_time=$(date -d "$snap_date" +%s)
    now_time=$(date +%s)
    age_days=$(( (now_time - snap_time) / 86400 ))

    # --- Apply Retention Rules ---
    keep_this_snapshot=0

    # Rule 1: Keep yearly snapshots
    if [ ${#kept_yearly[@]} -lt $KEEP_YEARLY ] && [ -z "${kept_yearly[$year]}" ]; then
        kept_yearly[$year]=1
        keep_this_snapshot=1
        echo "  -> Keeping (Yearly):  $snap"
    fi

    # Rule 2: Keep quarterly snapshots
    if [ ${#kept_quarterly[@]} -lt $KEEP_QUARTERLY ] && [ -z "${kept_quarterly[$year-q$quarter]}" ]; then
        kept_quarterly[$year-q$quarter]=1
        keep_this_snapshot=1
        echo "  -> Keeping (Quarterly): $snap"
    fi

    # Rule 3: Keep monthly snapshots
    if [ ${#kept_monthly[@]} -lt $KEEP_MONTHLY ] && [ -z "${kept_monthly[$year-$month]}" ]; then
        kept_monthly[$year-$month]=1
        keep_this_snapshot=1
        echo "  -> Keeping (Monthly):   $snap"
    fi

    # Rule 4: Keep daily snapshots
    if [ $age_days -lt $KEEP_DAILY ]; then
        keep_this_snapshot=1
        echo "  -> Keeping (Daily):     $snap"
    fi

    # If it was marked for keeping by ANY rule, add it to the keep list
    if [ $keep_this_snapshot -eq 1 ]; then
        echo "$snap" >> /tmp/zfs_sfg_snaps_keep_$$
    fi
done

# --- 3. Destroy Pruned Snapshots ---

# Use `comm` to find snapshots that are in the "all" list but NOT in the "keep" list.
# `comm -23` suppresses lines unique to file2 and lines common to both, showing only lines unique to file1.
echo "The following snapshots will be destroyed:"

# FIX: Ensure the 'keep' file exists, even if no snapshots were kept.
# This prevents a "No such file or directory" error from 'sort' on the first run.
[ ! -f /tmp/zfs_sfg_snaps_keep_$$ ] && touch /tmp/zfs_sfg_snaps_keep_$$

# Sort the files for `comm` to work correctly.
sort /tmp/zfs_sfg_snaps_all_$$ > /tmp/all_sorted
sort /tmp/zfs_sfg_snaps_keep_$$ > /tmp/keep_sorted

comm -23 /tmp/all_sorted /tmp/keep_sorted | while read -r snap_to_destroy; do
    echo "  - $snap_to_destroy"
    if [ "$DRY_RUN" -eq 0 ]; then
        zfs destroy -r "$snap_to_destroy"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to destroy snapshot $snap_to_destroy" >&2
        fi
    fi
done

echo "--- Pruning complete. ---"
