# Unified dstack rootfs image
# Use DSTACK_FLAVOR (via multiconfig) to select variant:
#   prod, dev, nvidia, nvidia-dev

# Default flavor settings (can be overridden by multiconfig)
DSTACK_FLAVOR ?= "prod"
DSTACK_NVIDIA ?= "0"
DSTACK_DEV ?= "0"

# Base configuration
include dstack-rootfs-base.inc

# Production or development mode
include ${@'dstack-rootfs-dev.inc' if d.getVar('DSTACK_DEV') == '1' else 'dstack-rootfs-prod.inc'}

# NVIDIA support (optional)
include ${@'dstack-rootfs-nvidia.inc' if d.getVar('DSTACK_NVIDIA') == '1' else ''}
