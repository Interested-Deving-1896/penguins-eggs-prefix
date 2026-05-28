# linux-distro-stage3 integration

This plugin documents how `penguins-eggs-prefix` consumes stage3 tarballs
produced by [linux-distro-stage3](https://github.com/Interested-Deving-1896/linux-distro-stage3).

## How it works

`build.sh` fetches the appropriate stage3 tarball from the `linux-distro-stage3`
GitHub releases API, matching on `{distro}_stage3_{release}_{arch}_*.tar.gz`.
The stage3 is used only as the bootstrap chroot base — it is not included in
the output prefix tarball.

When a `linux-distro-prefix` base tarball is also available, the stage3 is
still needed to provide the chroot environment for the penguins-eggs package
install step.

## Overriding the stage3 source

```bash
sudo ./build.sh \
  --distro debian --release trixie --arch amd64 \
  --stage3 /path/to/debian_stage3_trixie_amd64_20250101.tar.gz
```

Or via environment variable:

```bash
export STAGE3_TARBALL=/path/to/tarball.tar.gz
sudo ./build.sh --distro debian --arch amd64
```
