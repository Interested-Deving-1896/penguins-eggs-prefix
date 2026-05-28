# penguins-eggs-prefix

Fork of [linux-distro-prefix](https://github.com/Interested-Deving-1896/linux-distro-prefix) with [penguins-eggs](https://github.com/Interested-Deving-1896/penguins-eggs) integration.

Builds a Gentoo prefix extended with ISO production tools (squashfs-tools, xorriso, grub, syslinux) for use with penguins-eggs. Optionally produces a naked base ISO alongside the prefix tarball.

Stage3 rootfs tarballs are sourced from linux-distro-stage3. The base Gentoo prefix is pre-seeded from linux-distro-prefix releases when available, skipping the full bootstrap (~1 hour saved).

## Supported distros and architectures

Same matrix as linux-distro-prefix — 9 distros x 8 arches. See config/matrix.yml.

## Building locally

Requirements: root access, curl, coreutils, ~10 GB free disk space.

    git clone https://github.com/Interested-Deving-1896/penguins-eggs-prefix
    cd penguins-eggs-prefix

    # Build prefix tarball only
    sudo ./build.sh --distro debian --release trixie --arch amd64

    # Build prefix tarball + naked base ISO (requires penguins-eggs on host)
    sudo ./build.sh --distro debian --release trixie --arch amd64 --iso

### Options

| Flag       | Default    | Description                                              |
|------------|------------|----------------------------------------------------------|
| --distro   | debian     | Base distro for bootstrap chroot                         |
| --release  | trixie     | Distro release                                           |
| --arch     | amd64      | Target architecture                                      |
| --output   | ./         | Output directory                                         |
| --jobs     | nproc      | Parallel jobs                                            |
| --stage3   | (fetched)  | Path to a local stage3 tarball                           |
| --prefix   | (fetched)  | Path to a local linux-distro-prefix tarball              |
| --iso      | false      | Also produce a naked base ISO via penguins-eggs          |

### Output

    penguins_eggs_prefix_{distro}_{arch}_{YYYYMMDD}.tar.gz
    penguins_eggs_prefix_{distro}_{arch}_{YYYYMMDD}.tar.gz.sha256
    penguins_eggs_prefix_{distro}_{arch}.tar.gz          <- symlink to latest
    penguins_eggs_prefix_{distro}_{arch}_{YYYYMMDD}.iso  <- if --iso

## Using the prefix with penguins-eggs

    # Extract to /usr/local
    sudo tar zxf penguins_eggs_prefix_debian_amd64_YYYYMMDD.tar.gz -C /usr/local

    # Enter the prefix
    /usr/local/bin/startprefix

    # Or use with eggs produce --prefix
    sudo eggs produce --prefix

## Relationship to other projects

    linux-distro-stage3  (stage3 tarballs)
            |
            v
    linux-distro-prefix  (base Gentoo prefix tarballs)
            |
            v
    penguins-eggs-prefix  <- this repo (prefix + ISO production tools)
            |
            v
    penguins-eggs all-features  (eggs produce --prefix)
            |
            v
            ISO

## License

MIT
