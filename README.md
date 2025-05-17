Переведи это на русский
# Arch_Local_Repo - Arch Linux Mirror Sync Script

## Description

This script synchronizes a local Arch Linux mirror with official upstream mirrors. It's designed to provide a local repository and the ability to upgrade/install the system from scratch in case of no internet. . It also includes a feature to automatically index local custom repositories.

## Features

-   **Bandwidth Efficient:** Checks for remote updates via HTTP before initiating an rsync, reducing unnecessary data transfer.
-   **Mirror Failover:** Automatically selects the first responsive mirror from a predefined list.
-   **Bandwidth Limiting:** Option to limit rsync bandwidth usage.
-   **Automatic Local Repository Indexing:** Indexes local `core-local`, `extra-local`, `community-local`, and `multilib-local` repositories if they exist within the mirror structure.
-   **Cronjob Friendly:** Behaves differently (quieter, exits if no changes) when not run from a TTY.

## Prerequisites

This script is intended for Arch Linux. You will need the following packages installed:

-   `rsync`: For the main synchronization process.
-   `curl`: For fetching the `lastupdate` timestamp.
-   `pacman-contrib`: For the `repo-add` utility used to index local repositories.
-   `util-linux`: Provides `flock` for script locking (usually pre-installed).
-   `diffutils`: Provides `diff` for comparing timestamps (usually pre-installed).

You can install them using pacman:
```bash
sudo pacman -S rsync curl pacman-contrib util-linux diffutils
```

## Setup and Configuration

1.  **Clone or download the script:**
    Save the script to your desired location.

2.  **Make the script executable:**
    ```bash
    chmod +x sync-arch-mirror.sh
    ```

3.  **Configure the script (edit the following variables at the beginning of the script):**

    *   `target`:
        The script automatically sets this to `/home/$USER/arch-mirror-repo`. If you want to use a different location (e.g., `/srv/arch-mirror`), change this line:
        ```bash
        target="/your/desired/path/arch-mirror-repo"
        ```
        Ensure the user running the script has write permissions to this directory.

    *   `mirrors`:
        The script automatically sources mirrors from `/etc/pacman.d/mirrorlist`.
        It reads lines starting with `Server = `, expects HTTPS URLs, and transforms them into rsync URLs.
        For example, `https://repository.su/archlinux/$repo/os/$arch` becomes `rsync://repository.su/archlinux`.
        The script will try these mirrors in order and use the first one that responds.
        Ensure your `/etc/pacman.d/mirrorlist` file is populated with valid Arch Linux mirrors. If the file is not found or no suitable mirrors are parsed, the script may not be able to find a source URL and will exit.

    *   `bwlimit`:
        Set this to limit the bandwidth used by rsync in KiB/s. Use `0` to disable the limit (default).
        ```bash
        bwlimit=0 # No limit
        # or
        bwlimit=2000 # Limit to 2000 KiB/s
        ```

## Usage

Run the script directly:
```bash
./sync-arch-mirror.sh
```
The script will create the `target` directory if it doesn't exist. It uses a lock file (`syncrepo.lck` inside the `target` directory) to prevent multiple instances from running simultaneously.

## Permissions

The user executing the script needs:
-   Read and write permissions for the `target` directory (e.g., `/home/$USER/arch-mirror-repo` or your custom path). The script will attempt to create this directory if it doesn't exist, so write permission to its parent may also be needed initially.
-   Internet access to connect to the rsync mirrors and fetch the `lastupdate` file via HTTPS.

## Cronjob Setup

To automate the synchronization, you can set up a cronjob. For example, to run the script every hour:

```cron
0 * * * * /path/to/your/sync-arch-mirror.sh
```

When the script is run without a TTY (e.g., via cron), it will:
-   Run more quietly (suppressing progress output).
-   Exit immediately if the `lastupdate` timestamp indicates no changes on the remote mirror (after syncing the `lastsync` file).

## Local Repository Indexing

The script includes a section to automatically create or update database files for local repositories named `core-local`, `extra-local`, `community-local`, and `multilib-local`.
It expects these repositories to be structured as follows within your main mirror `target` directory:
```
<target>/core/os/<arch>/  (for packages that would go into core-local.db.tar.gz)
<target>/extra/os/<arch>/ (for packages that would go into extra-local.db.tar.gz)
... and so on.
```
For each repository (`core`, `extra`, `community`, `multilib`):
1.  It checks if a directory like `$target/$repo/os/$(uname -m)` exists.
2.  If it exists, it runs `repo-add` to create/update a `<repo>-local.db.tar.gz` file using all `*.pkg.tar.zst` files found in that directory.

Example: If you have custom packages in `$target/extra/os/x86_64/`, the script will generate/update `$target/extra/os/x86_64/extra-local.db.tar.gz`.

This is useful if you maintain your own custom packages and want to serve them via the same local mirror structure.

# Notes
Synchronizing for the first time will take quite some time. Full mirror with core, extra, images, iso kde-unstable, multilib will take 106 GB
