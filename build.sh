#!/usr/bin/env bash
# build.sh — build a penguins-eggs Gentoo prefix tarball for any Linux distro + arch
#
# Fork of linux-distro-prefix. Extends the base Gentoo prefix with packages
# needed by penguins-eggs for ISO production (squashfs-tools, xorriso, grub,
# live-boot hooks). Optionally produces a naked base ISO alongside the tarball.
#
# Usage:
#   sudo ./build.sh --distro debian  --release trixie  --arch amd64
#   sudo ./build.sh --distro alpine  --release 3.21    --arch arm64 --iso
#
# The stage3 rootfs is sourced from linux-distro-stage3 GitHub releases
# (or a local tarball if STAGE3_TARBALL is set). The base Gentoo prefix can
# be pre-seeded from a linux-distro-prefix release (PREFIX_TARBALL).
#
# Output: penguins_eggs_prefix_{distro}_{arch}_{YYYYMMDD}.tar.gz
#         penguins_eggs_prefix_{distro}_{arch}_{YYYYMMDD}.iso  (if --iso)
#
# Supported distros: debian ubuntu devuan arch fedora alpine void opensuse gentoo
# Supported arches:  amd64 arm64 armhf riscv64 ppc64el s390x loong64 i386

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
DISTRO="${DISTRO:-debian}"
RELEASE="${RELEASE:-trixie}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
JOBS="${JOBS:-$(nproc)}"
STAGE3_TARBALL="${STAGE3_TARBALL:-}"        # override: path to a local stage3 tarball
PREFIX_TARBALL="${PREFIX_TARBALL:-}"        # override: pre-seed from a linux-distro-prefix tarball
STAGE3_REPO="${STAGE3_REPO:-Interested-Deving-1896/linux-distro-stage3}"
PREFIX_REPO="${PREFIX_REPO:-Interested-Deving-1896/linux-distro-prefix}"
PREFIX_DIR="${PREFIX_DIR:-/usr/local/gentoo}"
BUILD_ISO="${BUILD_ISO:-false}"             # set true or pass --iso to also produce a naked base ISO
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROOT="${SCRIPT_DIR}/chroot"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --distro)   DISTRO="$2";           shift 2 ;;
    --release)  RELEASE="$2";          shift 2 ;;
    --arch)     ARCH="$2";             shift 2 ;;
    --output)   OUTPUT_DIR="$2";       shift 2 ;;
    --jobs)     JOBS="$2";             shift 2 ;;
    --stage3)   STAGE3_TARBALL="$2";   shift 2 ;;
    --prefix)   PREFIX_TARBALL="$2";   shift 2 ;;
    --chroot)   CHROOT="$2";           shift 2 ;;
    --iso)      BUILD_ISO=true;        shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

export DISTRO RELEASE ARCH JOBS PREFIX_DIR CHROOT

# ── validation ────────────────────────────────────────────────────────────────
SUPPORTED_DISTROS=(debian ubuntu devuan arch fedora alpine void opensuse gentoo)
SUPPORTED_ARCHES=(amd64 arm64 armhf riscv64 ppc64el s390x loong64 i386)

_in_list() { local v="$1"; shift; for x in "$@"; do [[ "$x" == "$v" ]] && return 0; done; return 1; }

_in_list "$DISTRO" "${SUPPORTED_DISTROS[@]}" || {
  echo "Unsupported distro: ${DISTRO}. Supported: ${SUPPORTED_DISTROS[*]}" >&2; exit 1
}
_in_list "$ARCH" "${SUPPORTED_ARCHES[@]}" || {
  echo "Unsupported arch: ${ARCH}. Supported: ${SUPPORTED_ARCHES[*]}" >&2; exit 1
}
[[ $EUID -eq 0 ]] || { echo "Must run as root (sudo ./build.sh ...)" >&2; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
info() { echo "[prefix] $*"; }
die()  { echo "[prefix] ERROR: $*" >&2; exit 1; }

# ── QEMU setup (cross-arch) ───────────────────────────────────────────────────
HOST_UNAME="$(uname -m)"

declare -A ARCH_TO_UNAME=(
  [amd64]=x86_64 [arm64]=aarch64 [armhf]=armv7l
  [riscv64]=riscv64 [ppc64el]=ppc64le [s390x]=s390x
  [loong64]=loongarch64 [i386]=i686
)
declare -A ARCH_TO_QEMU=(
  [arm64]=aarch64 [armhf]=arm [riscv64]=riscv64
  [ppc64el]=ppc64le [s390x]=s390x [loong64]=loongarch64 [i386]=i386
)

TARGET_UNAME="${ARCH_TO_UNAME[$ARCH]:-}"
QEMU_SUFFIX="${ARCH_TO_QEMU[$ARCH]:-}"

setup_qemu() {
  [[ "$TARGET_UNAME" == "$HOST_UNAME" ]] && return 0
  [[ "$HOST_UNAME" == "x86_64" && "$TARGET_UNAME" == "i686" ]] && return 0
  [[ -n "$QEMU_SUFFIX" ]] || die "No QEMU mapping for target arch ${ARCH}"

  info "Cross-arch build: host=${HOST_UNAME} target=${ARCH} — setting up QEMU"

  if ! command -v "qemu-${QEMU_SUFFIX}-static" &>/dev/null; then
    if command -v apt-get &>/dev/null; then
      apt-get install -y --no-install-recommends qemu-user-static binfmt-support
    elif command -v dnf &>/dev/null; then
      dnf install -y qemu-user-static
    elif command -v pacman &>/dev/null; then
      pacman -S --noconfirm qemu-user-static
    else
      die "Cannot install qemu-user-static — install it manually"
    fi
  fi

  if command -v update-binfmts &>/dev/null; then
    update-binfmts --enable
  elif systemctl is-active systemd-binfmt &>/dev/null 2>&1; then
    systemctl restart systemd-binfmt
  fi
  info "QEMU binfmt registered for ${ARCH}"
}

inject_qemu() {
  [[ -n "$QEMU_SUFFIX" ]] || return 0
  [[ "$TARGET_UNAME" == "$HOST_UNAME" ]] && return 0
  [[ "$HOST_UNAME" == "x86_64" && "$TARGET_UNAME" == "i686" ]] && return 0
  local qemu_bin="/usr/bin/qemu-${QEMU_SUFFIX}-static"
  [[ -f "$qemu_bin" ]] || return 0
  mkdir -p "${CHROOT}/usr/bin"
  cp "$qemu_bin" "${CHROOT}/usr/bin/"
  info "Injected ${qemu_bin} into chroot"
}

remove_qemu() {
  rm -f "${CHROOT}/usr/bin/qemu-"*"-static"
}

# ── pseudo-fs mounts ──────────────────────────────────────────────────────────
mount_pseudo() {
  mkdir -p "${CHROOT}"/{proc,sys,dev,dev/pts}
  mount -t proc  none          "${CHROOT}/proc"
  mount --bind   /sys          "${CHROOT}/sys"     && mount --make-slave "${CHROOT}/sys"
  mount --bind   /dev          "${CHROOT}/dev"     && mount --make-slave "${CHROOT}/dev"
  mount --bind   /dev/pts      "${CHROOT}/dev/pts" && mount --make-slave "${CHROOT}/dev/pts"
  mount -t tmpfs -o mode=1777 none "${CHROOT}/dev/shm"
}

umount_pseudo() {
  for mp in dev/shm dev/pts dev sys proc; do
    mountpoint -q "${CHROOT}/${mp}" && umount "${CHROOT}/${mp}" || true
  done
}

# ── stage3 acquisition ────────────────────────────────────────────────────────
fetch_stage3() {
  if [[ -n "$STAGE3_TARBALL" ]]; then
    info "Using local stage3: ${STAGE3_TARBALL}"
    cp "$STAGE3_TARBALL" "${SCRIPT_DIR}/stage3.tar.gz"
    return
  fi

  info "Fetching latest stage3 for ${DISTRO}/${RELEASE}/${ARCH} from ${STAGE3_REPO} releases"
  local api_url="https://api.github.com/repos/${STAGE3_REPO}/releases/latest"
  local pattern="${DISTRO}_stage3_${RELEASE}_${ARCH}_"
  local download_url
  download_url=$(curl -fsSL "$api_url" \
    | grep browser_download_url \
    | grep "${pattern}" \
    | grep -v '\.sha256' \
    | tr -d '"' \
    | sed 's/.*browser_download_url: //' \
    | head -1)

  [[ -n "$download_url" ]] || die "No stage3 release found for ${DISTRO}/${RELEASE}/${ARCH} in ${STAGE3_REPO}"
  info "Downloading: ${download_url}"
  curl -fL "$download_url" -o "${SCRIPT_DIR}/stage3.tar.gz"
}

# ── base prefix acquisition (optional pre-seed from linux-distro-prefix) ──────
fetch_base_prefix() {
  if [[ -n "$PREFIX_TARBALL" ]]; then
    info "Pre-seeding from local linux-distro-prefix tarball: ${PREFIX_TARBALL}"
    mkdir -p "${CHROOT}/usr/local"
    tar zxf "$PREFIX_TARBALL" -C "${CHROOT}/usr/local"
    return
  fi

  # Try to fetch from linux-distro-prefix releases (non-fatal — bootstrap from scratch if absent)
  info "Attempting to fetch base prefix for ${DISTRO}/${ARCH} from ${PREFIX_REPO} releases"
  local api_url="https://api.github.com/repos/${PREFIX_REPO}/releases/latest"
  local pattern="linux_distro_prefix_${DISTRO}_${ARCH}_"
  local download_url
  download_url=$(curl -fsSL "$api_url" 2>/dev/null \
    | grep browser_download_url \
    | grep "${pattern}" \
    | grep -v '\.sha256' \
    | tr -d '"' \
    | sed 's/.*browser_download_url: //' \
    | head -1) || true

  if [[ -n "$download_url" ]]; then
    info "Pre-seeding from: ${download_url}"
    curl -fL "$download_url" -o "${SCRIPT_DIR}/base_prefix.tar.gz"
    mkdir -p "${CHROOT}/usr/local"
    tar zxf "${SCRIPT_DIR}/base_prefix.tar.gz" -C "${CHROOT}/usr/local"
    rm -f "${SCRIPT_DIR}/base_prefix.tar.gz"
  else
    info "No base prefix release found — bootstrapping from scratch (this will take longer)"
  fi
}

# ── chroot cleanup ────────────────────────────────────────────────────────────
cleanup_chroot() {
  umount_pseudo
  # Kill any stray processes still inside the chroot
  for root_link in $(find /proc/*/root 2>/dev/null); do
    local link
    link="$(readlink -f "${root_link}" 2>/dev/null || true)"
    if echo "${link}" | grep -q "$(realpath "${CHROOT}" 2>/dev/null || echo "${CHROOT}")"; then
      local pid
      pid=$(basename "$(dirname "${root_link}")")
      kill -STOP "${pid}" 2>/dev/null || true
    fi
  done
  sleep 2
  for root_link in $(find /proc/*/root 2>/dev/null); do
    local link
    link="$(readlink -f "${root_link}" 2>/dev/null || true)"
    if echo "${link}" | grep -q "$(realpath "${CHROOT}" 2>/dev/null || echo "${CHROOT}")"; then
      local pid
      pid=$(basename "$(dirname "${root_link}")")
      kill -9 "${pid}" 2>/dev/null || true
    fi
  done
  sleep 2
}

# ── stage1 script (runs inside chroot as uid 1000) ────────────────────────────
write_stage1() {
  # If a base prefix was pre-seeded, skip bootstrap and go straight to
  # penguins-eggs packages. Otherwise run the full bootstrap first.
  local skip_bootstrap=false
  [[ -f "${CHROOT}/usr/local/gentoo/usr/bin/emerge" ]] && skip_bootstrap=true

  cat > "${CHROOT}/init" <<STAGE1
#!/bin/bash
set -e

export SHELL="/bin/bash"
export LC_ALL=C
export HOME=/usr/local
export MAKEOPTS="--jobs ${JOBS:-2}"
export EMERGE_DEFAULT_OPTS="--jobs ${JOBS:-2}"

PREFIX="${PREFIX_DIR:-/usr/local/gentoo}"

sudo mkdir -p "\$HOME"
sudo chown 1000:1000 /usr/local

unset LD_LIBRARY_PATH

SKIP_BOOTSTRAP=${skip_bootstrap}

if [[ "\$SKIP_BOOTSTRAP" != "true" ]]; then
  # Download Gentoo prefix bootstrap script
  curl -fsSL https://gitweb.gentoo.org/repo/proj/prefix.git/plain/scripts/bootstrap-prefix.sh \
    -o /tmp/bootstrap-prefix.sh

  # Patch: add zlib before binutils-config (required on some distros)
  sed -i -z \
    's@sys-devel/patch\n\t\tsys-devel/binutils-config@sys-devel/patch\n\t\tsys-libs/zlib\n\t\tsys-devel/binutils-config@g' \
    /tmp/bootstrap-prefix.sh

  chmod 0755 /tmp/bootstrap-prefix.sh

  # Bootstrap stages 1–3
  /tmp/bootstrap-prefix.sh "\$PREFIX" stage1
  /tmp/bootstrap-prefix.sh "\$PREFIX" stage2

  # Patch binutils static flags (avoids build failures on non-glibc hosts)
  sed -i "s@'-static' '-static-pie' '-fno-PIE -no-pie'@'-static'@g" \
    "\${PREFIX}/var/db/repos/gentoo/sys-devel/binutils/binutils-"*.ebuild
  for ebuild in "\${PREFIX}/var/db/repos/gentoo/sys-devel/binutils/"*.ebuild; do
    fname=\$(basename "\$ebuild")
    sed -i \
      "s@EBUILD \$fname .*@EBUILD \$fname \$(du -b "\$ebuild" | cut -f1) BLAKE2B \$(b2sum "\$ebuild" | cut -d' ' -f1) SHA512 \$(sha512sum "\$ebuild" | cut -d' ' -f1)@g" \
      "\${PREFIX}/var/db/repos/gentoo/sys-devel/binutils/Manifest"
  done

  /tmp/bootstrap-prefix.sh "\$PREFIX" stage3

  # Persist MAKEOPTS
  echo -e "MAKEOPTS=\"\${MAKEOPTS}\"\nEMERGE_DEFAULT_OPTS=\"\${EMERGE_DEFAULT_OPTS}\"" \
    > "\${PREFIX}/etc/portage/make.conf/make.conf"

  "\${PREFIX}/usr/bin/emerge" app-portage/prefix-toolkit
fi

# ── penguins-eggs additions ───────────────────────────────────────────────────
# ISO production tools needed by penguins-eggs
"\${PREFIX}/usr/bin/emerge" \
  app-portage/prefix-toolkit \
  sys-fs/squashfs-tools \
  dev-libs/libisoburn \
  sys-boot/grub \
  sys-boot/syslinux \
  app-arch/xz-utils \
  sys-apps/util-linux

# Expose startprefix
mkdir -p /usr/local/bin
cp "\${PREFIX}/startprefix" /usr/local/bin/startprefix

# Clean build artefacts
rm -rf "\${PREFIX}/tmp/"* "\${PREFIX}/var/cache/distfiles/"*

touch /usr/local/.finished
STAGE1
  chmod 0755 "${CHROOT}/init"
}

# ── main ──────────────────────────────────────────────────────────────────────
info "Building penguins-eggs prefix for ${DISTRO}/${RELEASE}/${ARCH}"
info "  CHROOT:     ${CHROOT}"
info "  PREFIX_DIR: ${PREFIX_DIR}"
info "  OUTPUT_DIR: ${OUTPUT_DIR}"
info "  JOBS:       ${JOBS}"
info "  BUILD_ISO:  ${BUILD_ISO}"

rm -rf "${CHROOT}"
mkdir -p "${CHROOT}" "${OUTPUT_DIR}"

# Acquire and unpack stage3
fetch_stage3
info "Unpacking stage3 into chroot"
tar xf "${SCRIPT_DIR}/stage3.tar.gz" -C "${CHROOT}"
rm -f "${SCRIPT_DIR}/stage3.tar.gz"

echo 'nameserver 1.1.1.1' > "${CHROOT}/etc/resolv.conf"

setup_qemu
inject_qemu

# Pre-seed from linux-distro-prefix release (skips full bootstrap if available)
fetch_base_prefix

mount_pseudo
write_stage1

info "=== Running prefix bootstrap ==="
env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  JOBS="${JOBS}" \
  PREFIX_DIR="${PREFIX_DIR}" \
  chroot --userspec=1000:1000 "${CHROOT}" /init

cleanup_chroot

if [[ ! -f "${CHROOT}/usr/local/.finished" ]]; then
  die "Bootstrap did not complete — /usr/local/.finished not found"
fi

# Package prefix tarball
info "=== Packaging prefix tarball ==="
local_date=$(date +"%Y%m%d")
tarball="${OUTPUT_DIR}/penguins_eggs_prefix_${DISTRO}_${ARCH}_${local_date}.tar.gz"
tar zcf "$tarball" -C "${CHROOT}/usr/local" .
sha256sum "$tarball" > "${tarball}.sha256"
ln -sf "$(basename "$tarball")" "${OUTPUT_DIR}/penguins_eggs_prefix_${DISTRO}_${ARCH}.tar.gz"

remove_qemu
rm -f "${CHROOT}/etc/resolv.conf"

info "Prefix done: ${tarball} ($(du -sh "$tarball" | cut -f1))"

# Optionally produce a naked base ISO via penguins-eggs
if [[ "$BUILD_ISO" == "true" ]]; then
  info "=== Producing naked base ISO ==="
  if ! command -v eggs &>/dev/null; then
    die "--iso requires penguins-eggs to be installed on the host (eggs command not found)"
  fi

  # Extract prefix into a temporary rootfs and invoke eggs produce --prefix
  iso_rootfs="${SCRIPT_DIR}/iso_rootfs"
  rm -rf "$iso_rootfs"
  mkdir -p "$iso_rootfs/usr/local"
  tar zxf "$tarball" -C "$iso_rootfs/usr/local"

  EGGS_PREFIX_ROOTFS="$iso_rootfs" \
    eggs produce --prefix \
      --basename "penguins_eggs_prefix_${DISTRO}_${ARCH}_${local_date}" \
      --output "${OUTPUT_DIR}"

  rm -rf "$iso_rootfs"
  info "ISO done: ${OUTPUT_DIR}/penguins_eggs_prefix_${DISTRO}_${ARCH}_${local_date}.iso"
fi
