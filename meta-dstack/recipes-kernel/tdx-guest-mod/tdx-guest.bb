SUMMARY = "TDX guest kernel module for Intel Trust Domain Extensions"
DESCRIPTION = "${SUMMARY}"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

inherit module

REPO_ROOT = "${THISDIR}/../../.."
SRC_DIR = "${REPO_ROOT}/dstack/mod-tdx-guest"

SRC_URI = "file://${SRC_DIR}"

S = "${WORKDIR}/${SRC_DIR}"

RPROVIDES:${PN} += "kernel-module-tdx-guest"