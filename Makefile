ifeq ($(BBPATH),)
$(error BBPATH is not set. Run `source dev-setup` first)
endif

.PHONY: all dist clean-dstack clean-initrd images

BUILD_DIR ?= bb-build
BUILD_IMAGES_DIR ?= ${BUILD_DIR}/tmp/deploy/images/tdx
DIST_DIR ?= ${BUILD_DIR}/dist
export BUILD_DIR
export DIST_DIR

DIST_NAMES ?= dstack dstack-dev
ROOTFS_IMAGE_NAMES = $(addsuffix -rootfs,${DIST_NAMES})

all: dist

-include $(wildcard mk.d/*.mk)

dist: images
	$(foreach dist_name,${DIST_NAMES},./mkimage.sh --dist-name $(dist_name);)

images:
	bitbake dstack-initramfs dstack-ovmf $(ROOTFS_IMAGE_NAMES)

clean-dstack:
	bitbake -c cleansstate dstack-guest $(ROOTFS_IMAGE_NAMES)

clean-initrd:
	bitbake -c cleansstate dstack-initramfs
