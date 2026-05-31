SUMMARY = "dstack Linux kernel 6.17.6 built from tarball"
DESCRIPTION = "Custom dstack kernel based on upstream Linux 6.17.6 with tiny Kconfig baseline tuned for TDX guests"
SECTION = "kernel"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

PV = "6.17.6"
LINUX_VERSION = "${PV}"

inherit kernel

FILESEXTRAPATHS:prepend := "${THISDIR}/files/6.17:${THISDIR}/files:"

DEPENDS += "libyaml-native openssl-native util-linux-native elfutils-native"

SRC_URI = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PV}.tar.xz;downloadfilename=linux-${PV}.tar.xz \
           file://defconfig \
           file://0001-x86-tdx-select-dma-direct-remap.patch \
"

SRC_URI[sha256sum] = "8ecfbc6b693448abb46144a8d04d1e1631639c7661c1088425a2e5406f13c69c"

S = "${UNPACKDIR}/linux-${PV}"

LINUX_VERSION_EXTENSION = "-dstack"
KERNEL_VERSION_EXTENSION = "-dstack"

# Enable BTF debug info for bpftool and out-of-tree modules (ZFS, WireGuard, etc.)
KERNEL_DEBUG = "True"

# Keep packaging aligned with our tiny x86_64 guest machines.
COMPATIBLE_MACHINE = "(tdx|sev-snp|qemux86-64)"

do_deploy:append() {
    install -m 0644 ${B}/.config ${DEPLOYDIR}/kernel-config
}
