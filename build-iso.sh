#!/usr/bin/env bash
# build-iso.sh - remaster the official Linux Mint 22.x Xfce ISO into a bootable
# "Windows11Revive" ISO: Windows 11 look, Firefox, LibreOffice, Java 8 for
# Minecraft 1.7.10, zram and low-RAM tuning, all baked in.
#
# Usage:
#   sudo ./build-iso.sh linuxmint-22.3-xfce-64bit.iso [Windows11Revive.iso]
#
# Needs: 64-bit Linux host, root, internet, ~18 GB free disk, and
#   sudo apt install xorriso squashfs-tools
#
# Optional: EXPECT_SHA256=<hash> to verify the input ISO before using it.
#
# How it works: the live system lives in /casper/filesystem.squashfs inside the ISO.
# We unpack it, chroot into it, run winlike-install.sh (WINLIKE_CHROOT=1 mode, which
# only writes defaults to /etc/skel so both the live session and the installed
# system get them), repack it, and swap it into a copy of the original ISO while
# replaying the original BIOS/UEFI boot setup. The kernel is never upgraded, so the
# ISO's boot files stay matched to the filesystem.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/winlike-install.sh"
WORK="${WORK:-$PWD/winlike-iso-work}"
ROOTFS="$WORK/rootfs"
MOUNTS=()

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  echo "Usage: sudo $0 <linuxmint-22.x-xfce-64bit.iso> [output.iso]" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 ..."
[[ -n "${1:-}" ]] || usage
SRC_ISO="$(readlink -f "$1")"
OUT_ISO="$(readlink -m "${2:-Windows11Revive.iso}")"
[[ -f "$SRC_ISO" ]] || die "Input ISO not found: $1"
[[ -f "$INSTALLER" ]] || die "winlike-install.sh must be next to this script ($INSTALLER)"
[[ "$SRC_ISO" != "$OUT_ISO" ]] || die "Output must be a different file from the input ISO"

for c in xorriso unsquashfs mksquashfs chroot md5sum sha256sum; do
  command -v "$c" >/dev/null || die "Missing '$c'. Install with: sudo apt install xorriso squashfs-tools"
done

[[ ! -e "$WORK" ]] || die "Work folder already exists: $WORK
Delete it first with:  sudo rm -rf '$WORK'"

avail_gb=$(df --output=avail -B1G "$(dirname "$WORK")" | tail -n1 | tr -d ' ')
(( avail_gb >= 18 )) || die "Only ${avail_gb} GB free in $(dirname "$WORK"); need about 18 GB."

cleanup() {
  set +e
  local i
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    umount -lf "${MOUNTS[i]}" 2>/dev/null
  done
  rm -f "$ROOTFS/usr/sbin/policy-rc.d" 2>/dev/null
}
trap cleanup EXIT

if [[ -n "${EXPECT_SHA256:-}" ]]; then
  step "Verifying input ISO checksum"
  got=$(sha256sum "$SRC_ISO" | cut -d' ' -f1)
  [[ "$got" == "$EXPECT_SHA256" ]] || die "Checksum mismatch.
expected: $EXPECT_SHA256
got:      $got"
  echo "Checksum OK"
fi

mkdir -p "$WORK"

# ---------------------------------------------------------------- extract ---
step "Extracting the live filesystem from the ISO"
xorriso -osirrox on -indev "$SRC_ISO" \
  -extract /casper/filesystem.squashfs "$WORK/filesystem.squashfs" >/dev/null 2>&1 || true
[[ -s "$WORK/filesystem.squashfs" ]] \
  || die "Could not find /casper/filesystem.squashfs in the ISO. Is this a Linux Mint 22.x Xfce ISO?"
# optional: checksum list (updated below if present)
xorriso -osirrox on -indev "$SRC_ISO" -extract /md5sum.txt "$WORK/md5sum.txt" >/dev/null 2>&1 || true

step "Unpacking the filesystem (a few minutes)"
unsquashfs -f -d "$ROOTFS" "$WORK/filesystem.squashfs" >/dev/null
[[ -x "$ROOTFS/bin/bash" || -x "$ROOTFS/usr/bin/bash" ]] || die "Unpacked filesystem looks wrong (no bash)."

# ----------------------------------------------------------------- chroot ---
step "Preparing the chroot"
mount -t proc proc "$ROOTFS/proc";    MOUNTS+=("$ROOTFS/proc")
mount -t sysfs sys "$ROOTFS/sys";     MOUNTS+=("$ROOTFS/sys")
mount --bind /dev "$ROOTFS/dev";      MOUNTS+=("$ROOTFS/dev")
mount --bind /dev/pts "$ROOTFS/dev/pts"; MOUNTS+=("$ROOTFS/dev/pts")
mount -t tmpfs tmpfs "$ROOTFS/run";   MOUNTS+=("$ROOTFS/run")

# DNS for apt/git inside the chroot (restored afterwards)
if [[ -e "$ROOTFS/etc/resolv.conf" || -L "$ROOTFS/etc/resolv.conf" ]]; then
  mv "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.winlike-orig"
fi
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# Never start services while installing packages in the chroot
printf '#!/bin/sh\nexit 101\n' >"$ROOTFS/usr/sbin/policy-rc.d"
chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"

cp "$INSTALLER" "$ROOTFS/tmp/winlike-install.sh"

kernels() {
  chroot "$ROOTFS" /bin/sh -c \
    "dpkg-query -W -f='\${Package} \${Version}\n' 'linux-image-*' 'linux-modules-*' 2>/dev/null | sort" || true
}
KERNELS_BEFORE="$(kernels)"

step "Running winlike-install.sh inside the image (10-30 minutes)"
chroot "$ROOTFS" /usr/bin/env -i HOME=/root TERM=xterm \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  WINLIKE_CHROOT=1 bash /tmp/winlike-install.sh

KERNELS_AFTER="$(kernels)"
if [[ "$KERNELS_BEFORE" != "$KERNELS_AFTER" ]]; then
  die "A kernel package changed inside the image; the ISO would not boot.
before:
$KERNELS_BEFORE
after:
$KERNELS_AFTER"
fi
echo "Kernel packages unchanged (good)."

step "Cleaning up the image"
chroot "$ROOTFS" apt-get clean || true
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin \
       "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* "$ROOTFS"/root/.cache 2>/dev/null || true
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
rm -f "$ROOTFS/etc/resolv.conf"
if [[ -e "$ROOTFS/etc/resolv.conf.winlike-orig" || -L "$ROOTFS/etc/resolv.conf.winlike-orig" ]]; then
  mv "$ROOTFS/etc/resolv.conf.winlike-orig" "$ROOTFS/etc/resolv.conf"
fi

chroot "$ROOTFS" dpkg-query -W --showformat='${Package}\t${Version}\n' >"$WORK/filesystem.manifest"

# unmount before measuring and squashing so /dev /proc /sys /run are empty
for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do umount -lf "${MOUNTS[i]}"; done
MOUNTS=()

du -sx --block-size=1 "$ROOTFS" | cut -f1 | tr -d '\n' >"$WORK/filesystem.size"

# ---------------------------------------------------------------- repack ---
step "Compressing the new filesystem (slow: 20-60+ minutes)"
mksquashfs "$ROOTFS" "$WORK/new.squashfs" -comp xz -b 1M -noappend

# ------------------------------------------------------------ rebuild ISO ---
step "Building $OUT_ISO"
MAPS=(
  -map "$WORK/new.squashfs" /casper/filesystem.squashfs
  -map "$WORK/filesystem.size" /casper/filesystem.size
  -map "$WORK/filesystem.manifest" /casper/filesystem.manifest
)

if [[ -f "$WORK/md5sum.txt" ]]; then
  update_md5() {
    local rel="$1" file="$2" sum pat
    sum=$(md5sum "$file" | cut -d' ' -f1)
    pat="${rel//./\\.}"
    sed -i -E "s#^[0-9a-f]{32}( +)\./${pat}\$#${sum}\1./${rel}#" "$WORK/md5sum.txt"
  }
  update_md5 casper/filesystem.squashfs "$WORK/new.squashfs"
  update_md5 casper/filesystem.size "$WORK/filesystem.size"
  update_md5 casper/filesystem.manifest "$WORK/filesystem.manifest"
  MAPS+=(-map "$WORK/md5sum.txt" /md5sum.txt)
fi

rm -f "$OUT_ISO"
xorriso -indev "$SRC_ISO" -outdev "$OUT_ISO" \
  "${MAPS[@]}" \
  -boot_image any replay \
  -commit

[[ -s "$OUT_ISO" ]] || die "ISO was not created."

step "Boot setup in the new ISO (should list BIOS and UEFI entries)"
xorriso -indev "$OUT_ISO" -report_el_torito plain 2>&1 | grep -Ei 'el torito|boot img|bios|uefi|efi' || true

sha256sum "$OUT_ISO" | tee "$OUT_ISO.sha256"
ls -lh "$OUT_ISO"

step "Done"
cat <<EOF
Your ISO: $OUT_ISO
Free the work space with:  sudo rm -rf '$WORK'

Flash it to an 8 GB (or larger) USB stick with Balena Etcher or Rufus (DD mode),
then boot the Packard Bell from it. The boot menu will still say
"Linux Mint": that is the unchanged boot loader, the desktop is the new one.
EOF
