# Arch_Local_Repo

A collection of scripts to create a local Arch Linux mirror and manage a
local AUR repository.

## Contents
- **sync-arch-mirror.sh** – synchronize official Arch Linux repositories to a
  local disk with incremental indexing of packages.
- **sync-aur-local.sh** – build packages from AUR and maintain a local AUR
  repository through an interactive CLI.
- **arch-repo-manager.sh** – a unified interface for working with the mirror and
  AUR repository.

## Requirements
Install the following packages on Arch Linux:

- `rsync` and `curl` – for mirror synchronization
- `pacman-contrib` – provides `repo-add` for indexing packages
- `util-linux` and `diffutils` – for `flock` and `diff`
- `yay` – for building AUR packages

```bash
sudo pacman -S rsync curl pacman-contrib util-linux diffutils yay
```

## Usage
### sync-arch-mirror.sh
1. Set the `target` variable at the top of the file to the path of your mirror
   directory.
2. Run the script:
   ```bash
   ./sync-arch-mirror.sh
   ```
   The script chooses an available mirror from `/etc/pacman.d/mirrorlist`,
   downloads updates and re-indexes any local `*-local` repositories when needed.

### sync-aur-local.sh
Provides a menu for adding, removing and building AUR packages. The
`aur-local.db.tar.gz` database is updated only when packages change.
Run:
```bash
./sync-aur-local.sh
```

### arch-repo-manager.sh
Combines the functionality of the two scripts above and lets you manage the
mirror and AUR repository from a single menu. It also supports the parameters
`sync`, `sync-force`, `build-aur` and `update-aur` for automation.

```bash
./arch-repo-manager.sh
```

## Repository Structure
All data is stored in `~/arch-mirror-repo` by default. Subdirectories `core`,
`extra`, `community`, `multilib` and `aur` are created there. For each
architecture (`os/$(uname -m)`) package files and `*-local.db.tar.gz` database
files are kept.

## Notes
The initial synchronization can require over 100 GB of space. Running from
`cron` is supported – if nothing has changed, the script exits quickly with
minimal output.
