include dstack-rootfs-base.inc

IMAGE_INSTALL += "packagegroup-core-ssh-openssh strace tcpdump gdb gdbserver"
EXTRA_IMAGE_FEATURES += "debug-tweaks tools-profile"
