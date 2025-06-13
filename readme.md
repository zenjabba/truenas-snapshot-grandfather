# ZFS Son-Father-Grandfather Snapshot Script

This repository contains a robust Bash script for creating and managing ZFS snapshots on systems like TrueNAS, FreeBSD, or Linux. It implements a "Son-Father-Grandfather" (SFG) rotation scheme, which provides a sophisticated, multi-tiered retention policy that goes beyond what's typically available in basic periodic snapshot tools.

The goal of this script is to give you short-term, medium-term, and long-term recovery points without consuming excessive disk space.

## Features

*   **Configurable Retention:** Easily define how many daily, monthly, quarterly, and yearly snapshots to keep.
*   **Safe Dry-Run Mode:** Test the script's actions without creating or destroying any real snapshots.
*   **Recursive:** Automatically snapshots a dataset *and* all of its children.
*   **Zero Dependencies:** Runs using standard system tools (`zfs`, `grep`, `date`, etc.) found on any ZFS-capable system.
*   **Designed for Automation:** Perfect for use with `cron` for "set it and forget it" operation.
*   **Heavily Commented:** The script is commented to explain what each section does.

***

## How The Retention Policy Works

Every time the script runs, it performs two main actions:

1.  **CREATE:** It always creates a new, timestamped "daily" snapshot with the name format `autosnap_YYYY-MM-DD_HHMMSS`.

2.  **PRUNE:** This is the smart part. The script scans all snapshots matching the `autosnap_` prefix and decides which ones to keep based on the rules you define. A single snapshot can fulfill multiple roles.

For example, with the default settings:
*   **Daily:** Keeps the last **14** snapshots.
*   **Monthly:** Keeps the *first* snapshot taken in each of the last **3** months.
*   **Quarterly:** Keeps the *first* snapshot taken in each of the last **4** quarters.
*   **Yearly:** Keeps the *first* snapshot taken in each of the last **3** years.

A snapshot taken on `January 1st, 2024` could be kept because it's a recent daily, the first of the month, the first of the quarter, AND the first of the year. The script ensures that any snapshot meeting **at least one** of these criteria is kept. All others are destroyed.

***

## Installation and Setup Guide

Follow these steps carefully. We will use placeholder names that you must replace with your own.
*   `yourpool`: The name of your main ZFS pool (e.g., `tank`, `digitalmonks_dc_backup`).
*   `yourdataset`: The name of the dataset you want to back up (e.g., `data`, `zendc_backup`).

### Prerequisites

*   A system running TrueNAS or another OS with ZFS installed.
*   Shell access (SSH or the built-in Shell in the TrueNAS UI).
*   Root user privileges (most ZFS commands require this).

### Step 1: Place the Script on Your System

You need to save the `zfs-sfg-snapshot.sh` script to a safe location on your server.

**IMPORTANT:** Do NOT store the script on the ZFS dataset you intend to snapshot. If you ever need to restore that dataset from a snapshot, you would lose the script itself! A good practice is to create a separate `scripts` dataset on your main pool.

1.  Open the shell on your TrueNAS system.

2.  Create a dedicated dataset for your scripts (if you don't already have one):
    ```bash
    zfs create yourpool/scripts
    ```

3.  Navigate to this new directory:
    ```bash
    cd /mnt/yourpool/scripts
    ```

4.  Create the script file using a text editor like `nano`:
    ```bash
    nano zfs-sfg-snapshot.sh
    ```

5.  Copy the entire contents of the `zfs-sfg-snapshot.sh` file from this repository and paste it into the `nano` editor.

6.  Save the file and exit nano by pressing `Ctrl+X`, then `Y`, then `Enter`.

7.  Make the script executable. This is a critical step!
    ```bash
    chmod +x zfs-sfg-snapshot.sh
    ```

### Step 2 (Optional): Configure the Retention Policy

If the default retention policy (14 daily, 3 monthly, 4 quarterly, 3 yearly) isn't what you want, you can easily change it.

1.  Open the script again with `nano`:
    ```bash
    nano zfs-sfg-snapshot.sh
    ```

2.  Find the configuration block at the top of the script and edit the numbers to match your needs:
    ```bash
    # --- Configuration: Retention Policy ---
    # Adjust these values to change the retention policy.
    KEEP_DAILY=14
    KEEP_MONTHLY=3
    KEEP_QUARTERLY=4 # 12 months = 4 quarters
    KEEP_YEARLY=3
    # --- End Configuration ---
    ```

3.  Save and exit the editor.

### Step 3: Test the Script with Dry Run Mode

**THIS IS THE MOST IMPORTANT STEP.** Never automate a script that can delete data without testing it first. The `--dry-run` flag tells the script to report what it *would do* without making any actual changes.

1.  In your shell, run the script with the `--dry-run` flag, followed by the full name of the dataset you want to snapshot.

    **Example:**
    ```bash
    /mnt/yourpool/scripts/zfs-sfg-snapshot.sh --dry-run yourpool/yourdataset
    ```

2.  **Analyze the output.** It will look something like this:
    ```
    --- DRY RUN MODE: No snapshots will be created or destroyed. ---
    Creating snapshot: yourpool/yourdataset@autosnap_2024-05-20_103000
    DRY-RUN: Would have run 'zfs snapshot -r "yourpool/yourdataset@autosnap_2024-05-20_103000"'
    Pruning snapshots for yourpool/yourdataset...
      -> Keeping (Daily):     yourpool/yourdataset@autosnap_...
      -> Keeping (Monthly):   yourpool/yourdataset@autosnap_...
    The following snapshots will be destroyed:
      - yourpool/yourdataset@some_old_autosnap_...
    --- Pruning complete. ---
    ```

3.  Review this output carefully. Does it look correct? Is it keeping the snapshots you expect and flagging the correct ones for deletion? If so, you can proceed.

### Step 4: Automate the Script with a Cron Job

Now we will tell TrueNAS to run this script automatically every day.

1.  In the TrueNAS Web UI, navigate to **System > Advanced > Cron Jobs**.
2.  Click the **ADD** button.
3.  Fill out the form with the following information:

    *   **Description:** Give it a memorable name, like `SFG Snapshot for my main data`.
    *   **Command:** Enter the **full, absolute path** to the script, followed by the full name of your dataset.
        ```
        /mnt/yourpool/scripts/zfs-sfg-snapshot.sh yourpool/yourdataset
        ```
    *   **User:** Select `root`. The script needs root permissions to manage ZFS.
    *   **Schedule:** Choose when you want the script to run. A good time is late at night or early in the morning when the system is not busy.
        *   Select the **Daily** preset.
        *   Set the **Hour** to `3` (for 3 AM).
        *   Set the **Minute** to `5` (for 3:05 AM).
    *   **Hide Standard Output / Hide Standard Error:** **LEAVE THESE UNCHECKED** initially. When unchecked, the system will email the root user's account if the script produces any output or errors. This is your best way to know if something is wrong. After you have confirmed for a few weeks that the script is running perfectly, you can check these boxes to reduce email notifications.

4.  Click **SAVE**.

You are all set! Your automated, multi-tiered snapshot system is now active. You can check on its work periodically by going to **Storage > Snapshots** in the TrueNAS UI.

***

## Troubleshooting & FAQ

*   **Error: `Permission denied` when running the script.**
    *   You forgot to make the script executable. Run `chmod +x /path/to/your/script.sh`.
    *   You are not running the script as the `root` user.

*   **Error in Cron Job: `Command not found`.**
    *   You did not use the full, absolute path to the script in the Cron Job command field. It must start with `/mnt/`.

*   **How do I snapshot multiple datasets?**
    *   The easiest way is to create a separate Cron Job for each dataset you want to snapshot. Simply repeat Step 4, changing the description and the dataset name in the command.

## License

This script is released under the MIT License. See the `LICENSE` file for more details. You are free to use, modify, and distribute it as you see fit.
