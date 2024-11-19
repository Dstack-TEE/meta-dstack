SUMMARY = "TDX guest kernel module for Intel Trust Domain Extensions"
DESCRIPTION = "${SUMMARY}"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

inherit module

SRC_URI = "git://github.com/Dstack-TEE/dstack.git;protocol=https;branch=master"
SRCREV = "06ab627e81b8a8930e4bc506e89b79e70a69a1b8"
S = "${WORKDIR}/git/mod-tdx-guest"

RPROVIDES:${PN} += "kernel-module-tdx-guest"
