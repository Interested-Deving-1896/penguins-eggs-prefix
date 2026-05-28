# linux-distro-prefix integration

This plugin documents how `penguins-eggs-prefix` consumes base prefix tarballs
produced by [linux-distro-prefix](https://github.com/Interested-Deving-1896/linux-distro-prefix).

## How it works

`build.sh` attempts to fetch the latest matching `linux_distro_prefix_{distro}_{arch}_*.tar.gz`
from the `linux-distro-prefix` GitHub releases API and pre-seeds the chroot with it.
This skips the full Gentoo prefix bootstrap (~1 hour), leaving only the
penguins-eggs-specific package installs to run.

If no matching release is found, the full bootstrap runs from scratch.

## Overriding the base prefix source

```bash
sudo ./build.sh \
  --distro debian --arch amd64 \
  --prefix /path/to/linux_distro_prefix_debian_amd64_20250101.tar.gz
```

Or via environment variable:

```bash
export PREFIX_TARBALL=/path/to/tarball.tar.gz
sudo ./build.sh --distro debian --arch amd64
```

## Pointing at a different prefix repo

```bash
export PREFIX_REPO=myorg/my-prefix-fork
sudo ./build.sh --distro debian --arch amd64
```
