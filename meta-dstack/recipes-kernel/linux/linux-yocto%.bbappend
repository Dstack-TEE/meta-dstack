FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

LINUX_VERSION_EXTENSION = "-dstack"

SRC_URI += "file://dstack-docker.cfg \
            file://dstack-docker.scc \
            file://dstack-tdx.cfg \
            file://dstack-tdx.scc \
            file://dstack-sysbox.cfg \
            file://dstack-sysbox.scc \
            file://dstack.cfg \
            file://dstack.scc"

# TDX guests need DMA_DIRECT_REMAP for shared (decrypted) coherent DMA so
# devices like NVMe can complete I/O. INTEL_TDX_GUEST does not select it
# upstream (and the symbol is promptless, so a .cfg fragment cannot set it),
# hence this Kconfig patch. Scoped to tdx machines only.
SRC_URI:append:tdx = " file://0001-x86-tdx-select-dma-direct-remap.patch"

KERNEL_FEATURES:append = " features/cgroups/cgroups.scc \
                          features/overlayfs/overlayfs.scc \
                          features/netfilter/netfilter.scc \
                          features/fuse/fuse.scc \
                          features/xfs/xfs.scc \
                          cfg/fs/squashfs.scc \
                          dstack-docker.scc \
                          dstack-sysbox.scc \
                          dstack.scc"

KERNEL_FEATURES:append = " ${@bb.utils.contains("DISTRO_FEATURES", "dm-verity", " features/device-mapper/dm-verity.scc", "" ,d)}"

KERNEL_FEATURES:append:tdx = " dstack-tdx.scc"

# Enable BTF
KERNEL_DEBUG = "True"

do_deploy:append() {
    install -m 0644 ${B}/.config ${DEPLOYDIR}/kernel-config
}
