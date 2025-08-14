SUMMARY = "A fast compression and decompression tool"
DESCRIPTION = "crabz (🦀) is a cross-platform command-line tool for compression and decompression, \
written in Rust. It supports multiple formats including gzip, bzip2, xz, and zstd with \
multi-threaded compression and decompression for improved performance."

HOMEPAGE = "https://github.com/sstadick/crabz"
BUGTRACKER = "https://github.com/sstadick/crabz/issues"
SECTION = "utils"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE-MIT;md5=d007016f5aa5131e3d7c2e3088ab227c"

# Use latest stable version
PV = "0.10.0+git${SRCPV}"
SRCREV = "91e58e3bdaaaf9838c14b5734947d82f2453be26"

SRC_URI = "git://github.com/sstadick/crabz.git;protocol=https;branch=main \
           file://unpigz \
          "
S = "${WORKDIR}/git"

# Build dependencies
DEPENDS = "cmake-native"

inherit cargo_bin

# Enable network access for cargo to download dependencies
do_compile[network] = "1"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${CARGO_BINDIR}/crabz ${D}${bindir}/crabz

    # Install unpigz wrapper script for compatibility
    install -m 0755 ${WORKDIR}/unpigz ${D}${bindir}/unpigz
}

# Package configuration
FILES:${PN} = "${bindir}/crabz ${bindir}/unpigz"
FILES:${PN}-dev = ""
FILES:${PN}-staticdev = ""

# Runtime dependencies
RDEPENDS:${PN} = ""

# Compatibility
COMPATIBLE_HOST = "(x86_64|i.86|aarch64|arm).*-linux"

# Package metadata
PROVIDES = "crabz unpigz"
RPROVIDES:${PN} = "crabz unpigz"

BBCLASSEXTEND = "native nativesdk"
