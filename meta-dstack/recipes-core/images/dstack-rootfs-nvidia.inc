NVIDIA_GROUP = "acpid \
    nvidia \
    nvidia-firmware \
    nvidia-persistenced \
    nvidia-fabricmanager \
    libnvidia-nscq \
    nvidia-container-toolkit \
    kernel-module-video \
    numactl \
"
KERNEL_MODULE_AUTOLOAD:append = " nvidia nvidia-drm nvidia-modeset nvidia-uvm video"
IMAGE_INSTALL:append = " ${NVIDIA_GROUP}"

install_nvidia_docker_config() {
    install -m 0644 ${THISDIR}/../dstack-guest/files/docker-daemon-nvidia.json ${IMAGE_ROOTFS}${sysconfdir}/docker/daemon.json
}
ROOTFS_POSTPROCESS_COMMAND:append = " install_nvidia_docker_config;"
