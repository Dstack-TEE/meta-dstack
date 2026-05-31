ifeq ($(BBPATH),)
$(error BBPATH is not set. Run `source dev-setup` first)
endif

.PHONY: all dist clean-dstack clean-initrd images images-common images-flavors

BB_BUILD_DIR ?= bb-build
DIST_DIR ?= ${BB_BUILD_DIR}/dist
export BB_BUILD_DIR
export DIST_DIR

# Flavor names map to multiconfig names: prod, dev, nvidia, nvidia-dev
FLAVORS ?= prod dev nvidia nvidia-dev

# Map flavor to dist name for mkimage.sh
flavor_to_dist = $(if $(filter prod,$1),dstack-cloud,$(if $(filter dev,$1),dstack-cloud-dev,$(if $(filter nvidia,$1),dstack-cloud-nvidia,$(if $(filter nvidia-dev,$1),dstack-cloud-nvidia-dev,$1))))

all: dist

-include $(wildcard mk.d/*.mk)

dist: images
	$(foreach flavor,$(FLAVORS),./mkimage.sh --dist-name $(call flavor_to_dist,$(flavor)) --flavor $(flavor);)

# Build common artifacts (shared across all flavors)
# dstack-guest is built here to avoid concurrent build conflicts in multiconfig
images-common:
	bitbake virtual/kernel dstack-initramfs dstack-ovmf

# Build flavor-specific artifacts using multiconfig (serial to avoid deadlock warnings)
images-flavors:
	$(foreach flavor,$(FLAVORS),bitbake mc:$(flavor):dstack-rootfs mc:$(flavor):dstack-uki;)

images: images-common images-flavors

clean:
	bitbake -c cleansstate virtual/kernel dstack-initramfs dstack-ovmf
	$(foreach flavor,$(FLAVORS),bitbake -c cleansstate mc:$(flavor):dstack-rootfs mc:$(flavor):dstack-uki;)

clean-dstack:
	bitbake -c cleansstate dstack-guest
	$(foreach flavor,$(FLAVORS),bitbake -c cleansstate mc:$(flavor):dstack-rootfs;)

clean-initrd:
	bitbake -c cleansstate dstack-initramfs
