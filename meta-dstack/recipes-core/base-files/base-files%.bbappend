FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://dstack-motd"

do_install:append() {
    if [ -f ${WORKDIR}/dstack-motd ];then
        bbnote "Installing custom dstack motd file"
        install -m 0644 ${WORKDIR}/dstack-motd ${D}${sysconfdir}/motd
    else
        bbwarn "Custom dstack-motd file not found in ${WORKDIR}"
        ls -la ${WORKDIR}
    fi

    # systemd-remount-fs re-applies fstab options to API filesystems listed
    # there, so the stock "defaults" entry would undo the nosuid,nodev,noexec
    # the initramfs mounts /proc with.
    sed -i -E 's#^(proc[[:space:]]+/proc[[:space:]]+proc[[:space:]]+)defaults#\1nosuid,nodev,noexec#' ${D}${sysconfdir}/fstab
    grep -Eq '^proc[[:space:]]+/proc[[:space:]]+proc[[:space:]]+nosuid,nodev,noexec' ${D}${sysconfdir}/fstab
}
