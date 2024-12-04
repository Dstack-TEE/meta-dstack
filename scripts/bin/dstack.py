#!/usr/bin/env python3

import argparse
import json
import logging
import os
import random
import string
import subprocess
import uuid
import configparser
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional
from functools import reduce

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def generate_config_paths():
    paths = [
        "/etc/dstack/client.conf",
        os.path.expanduser("~/.config/dstack/client.conf"),
    ]
    current_dir = os.getcwd()
    while current_dir != "/":
        paths.append(os.path.join(current_dir, ".dstack", "client.conf"))
        current_dir = os.path.dirname(current_dir)
    return paths


@dataclass
class PortMap:
    """Configuration for port mapping."""
    address: str
    protocol: str
    from_port: int
    to_port: int

    def to_dict(self) -> Dict:
        return {
            "address": self.address,
            "protocol": self.protocol,
            "from": self.from_port,
            "to": self.to_port
        }

@dataclass
class VMConfig:
    """Configuration for VM instance."""
    id: str
    name: str
    vcpu: int
    gpu: List[str]
    memory: int
    disk_size: int
    image: str
    port_map: List[PortMap]
    created_at_ms: int

    def to_dict(self) -> Dict:
        return {
            "id": self.id,
            "name": self.name,
            "vcpu": self.vcpu,
            "gpu": self.gpu,
            "memory": self.memory,
            "disk_size": self.disk_size,
            "image": self.image,
            "port_map": [p.to_dict() for p in self.port_map],
            "created_at_ms": self.created_at_ms
        }

def merge2(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        c = a.copy()
        for k, v in b.items():
            c[k] = merge2(a.get(k), v)
        return c
    if b is None:
        return a
    return b


def test_merge2():
    assert merge2({"a": 1}, {"b": 2}) == {"a": 1, "b": 2}
    assert merge2({"a": 1}, {"a": 2}) == {"a": 2}
    assert merge2({"a": {"b": 1}}, {"a": {"c": 2}}) == {"a": {"b": 1, "c": 2}}


def merge_dicts(*dicts):
    return reduce(merge2, dicts, {})


def test_merge_dicts():
    assert merge_dicts({"a": 1}, {"b": 2}) == {"a": 1, "b": 2}
    assert merge_dicts({"a": 1}, {"a": 2}) == {"a": 2}
    assert merge_dicts({"a": {"b": 1}}, {"a": {"c": 2}}) == {"a": {"b": 1, "c": 2}}
    assert merge_dicts({"a": {"b": 1}}, {"a": {"b": 2}}) == {"a": {"b": 2}}
    assert merge_dicts({"a": {"b": 1}}, {"a": {"b": 2}, "c": 3}) == {"a": {"b": 2}, "c": 3}
    assert merge_dicts({"a": 1}, {"b": 2}, {"c": 3}) == {"a": 1, "b": 2, "c": 3}
    assert merge_dicts({"a": 1}, {"a": 2}, {"c": 3}) == {"a": 2, "c": 3}


def ini_to_dict(filename):
    config = configparser.ConfigParser()
    config.read(filename)
    
    result = {}
    for section in config.sections():
        result[section] = {}
        for key, value in config.items(section):
            result[section][key] = value
    return result


def load_configs_merged(config_paths):
    config = {}
    for config_path in config_paths:
        if os.path.exists(config_path):
            logger.info(f"Loading configuration from {config_path}")
            config = merge_dicts(config, ini_to_dict(config_path))
    return config


@dataclass
class DStackConfig:
    """Configuration for DStack client."""
    docker_registry: Optional[str] = None
    image_path: str = './images'
    default_image_name: str = ''
    qemu_path: str = 'qemu-system-x86_64'

    @classmethod
    def load(cls) -> 'DStackConfig':
        """Load configuration from file."""
        cfgs = load_configs_merged(generate_config_paths())
        def cfg_get(section, key, fallback):
            if section in cfgs and key in cfgs[section]:
                return cfgs[section][key]
            return fallback
        me = cls()
        me.docker_registry = cfg_get('docker', 'registry', cls.docker_registry)
        me.image_path = os.path.abspath(cfg_get('image', 'path', cls.image_path))
        me.default_image_name = cfg_get('image', 'default', cls.default_image_name)
        me.qemu_path = cfg_get('qemu', 'path', cls.qemu_path)
        return me


class DStackManager:
    def __init__(self):
        self.run_path = os.path.abspath(os.getenv('RUN_PATH', './vms'))
        self.config = DStackConfig.load()

    def get_default_image_path(self) -> str:
        """Get the full default image path."""
        return os.path.join(self.config.image_path, self.config.default_image_name)

    def _generate_instance_id(self) -> str:
        """Generate a random instance ID."""
        return str(uuid.uuid4())

    def _read_compose_file(self, compose_file: str) -> str:
        """Read and validate compose file."""
        if not os.path.isfile(compose_file):
            raise FileNotFoundError(f"Compose file not found: {compose_file}")
        with open(compose_file, 'r') as f:
            return f.read()

    def _read_image_metadata(self, image_path: str) -> str:
        """Read and validate image metadata."""
        metadata_path = os.path.join(image_path, 'metadata.json')
        if not os.path.isfile(metadata_path):
            raise FileNotFoundError(f"Image metadata not found at {metadata_path}")
        
        try:
            with open(metadata_path, 'r') as f:
                metadata = json.load(f)
            rootfs_hash = metadata.get('rootfs_hash')
            if not rootfs_hash:
                raise ValueError("Rootfs hash not found in image info")
            return rootfs_hash
        except json.JSONDecodeError:
            raise ValueError(f"Invalid JSON in metadata file: {metadata_path}")

    def _create_directories(self, work_dir: str) -> tuple[str, str]:
        """Create necessary directories."""
        if os.path.exists(work_dir):
            raise FileExistsError(f"The instance already exists at {work_dir}")
        
        shared_dir = os.path.join(work_dir, 'shared')
        certs_dir = os.path.join(shared_dir, 'certs')
        os.makedirs(shared_dir, exist_ok=True)
        os.makedirs(certs_dir, exist_ok=True)
        return shared_dir, certs_dir

    def _convert_memory_to_mb(self, memory: str) -> int:
        """Convert memory string to MB."""
        if memory.upper().endswith('T'):
            return int(memory[:-1]) * 1024 * 1024
        if memory.upper().endswith('G'):
            return int(memory[:-1]) * 1024
        if memory.upper().endswith('M'):
            return int(memory[:-1])
        return int(memory)

    def _parse_port_mapping(self, port_str: str) -> PortMap:
        """Parse port mapping string in format 'protocol[:address]:from:to'."""
        try:
            parts = port_str.split(':')
            if len(parts) == 3:
                proto, from_port, to_port = parts
                address = "127.0.0.1"  # default to localhost
            elif len(parts) == 4:
                proto, address, from_port, to_port = parts
            else:
                raise ValueError("Invalid port mapping format. Use 'protocol[:address]:from:to'")

            return PortMap(
                address=address,
                protocol=proto.lower(),
                from_port=int(from_port),
                to_port=int(to_port)
            )
        except ValueError as e:
            raise ValueError(f"Invalid port mapping '{port_str}': {str(e)}")

    def setup_instance(self, args: argparse.Namespace) -> None:
        """Set up a new instance with the provided configuration."""
        try:
            # Generate instance ID if work_dir not provided
            instance_id = os.path.basename(args.dir) if args.dir else self._generate_instance_id()
            work_dir = args.dir or os.path.join(self.run_path, instance_id)
            
            # Create directories
            shared_dir, certs_dir = self._create_directories(work_dir)
            
            # Read compose file
            compose_content = self._read_compose_file(args.compose_file)
            
            # Create app-compose.json
            app_compose = {
                "manifest_version": 1,
                "name": "example",
                "version": "1.0.0",
                "features": [],
                "runner": "docker-compose",
                "docker_compose_file": compose_content
            }
            with open(os.path.join(shared_dir, 'app-compose.json'), 'w') as f:
                json.dump(app_compose, f, indent=4)

            # Read image metadata and create config.json
            image_path = args.image or self.get_default_image_path()
            rootfs_hash = self._read_image_metadata(image_path)
            with open(os.path.join(shared_dir, 'config.json'), 'w') as f:
                json.dump({"rootfs_hash": rootfs_hash, "docker_registry": self.config.docker_registry}, f, indent=4)

            # Create VM manifest
            memory = self._convert_memory_to_mb(str(args.memory))
            disk_size = self._convert_memory_to_mb(str(args.disk)) // 1024
            port_map = []
            if args.port:
                for port_str in args.port:
                    port_map.append(self._parse_port_mapping(port_str))

            vm_config = VMConfig(
                id=instance_id,
                name="example",
                vcpu=args.vcpus,
                gpu=args.gpu or [],
                memory=memory,
                disk_size=disk_size,
                image=os.path.basename(image_path),
                port_map=port_map,
                created_at_ms=int(datetime.now().timestamp() * 1000)
            )
            
            with open(os.path.join(work_dir, 'vm-manifest.json'), 'w') as f:
                json.dump(vm_config.to_dict(), f, indent=4)

            logger.info(f"Work directory prepared successfully at: {work_dir}")

        except Exception as e:
            logger.error(f"Failed to setup instance: {str(e)}")
            raise

    def run_instance(self, vm_dir: str, memory: Optional[str] = None, vcpus: Optional[int] = None) -> None:
        """Run a VM instance from the specified directory.

        Args:
            vm_dir: Directory containing the VM configuration
            memory: Optional memory size override (e.g., '2G', '512M')
            vcpus: Optional number of virtual CPUs override
        """
        manifest_path = os.path.join(vm_dir, 'vm-manifest.json')
        if not os.path.exists(manifest_path):
            raise ValueError(f"VM manifest not found in {vm_dir}")

        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Get image path and metadata
        image_path = os.path.join(self.config.image_path, manifest['image'])
        img_metadata_path = os.path.join(image_path, 'metadata.json')
        
        if not os.path.exists(img_metadata_path):
            raise ValueError(f"Image metadata not found at {img_metadata_path}")

        with open(img_metadata_path, 'r') as f:
            img_metadata = json.load(f)

        # Prepare QEMU arguments
        mem = memory if memory else f"{manifest['memory']}M"
        vcpu_count = vcpus if vcpus is not None else manifest['vcpu']
        disk_size = manifest['disk_size']
        gpus = manifest.get('gpu', [])

        vda = os.path.join(vm_dir, 'hda.img')
        config_dir = os.path.join(vm_dir, 'shared')
        
        # Create disk if it doesn't exist
        if not os.path.exists(vda):
            subprocess.run(['qemu-img', 'create', '-f', 'qcow2', vda, f"{disk_size}G"], check=True)

        cid = random.randint(1, 10000) + 3

        # Prepare QEMU command
        cmd = [
            self.config.qemu_path,
            '-accel', 'kvm',
            '-m', mem,
            '-smp', str(vcpu_count),
            '-cpu', 'host',
            '-machine', 'q35,kernel_irqchip=split,confidential-guest-support=tdx,hpet=off',
            '-object', 'tdx-guest,id=tdx',
            '-nographic',
            '-nodefaults',
            '-chardev', 'stdio,id=ser0,signal=on',
            '-serial', 'chardev:ser0',
            '-kernel', os.path.join(image_path, img_metadata['kernel']),
            '-initrd', os.path.join(image_path, img_metadata['initrd']),
            '-bios', os.path.join(image_path, img_metadata['bios']),
            '-cdrom', os.path.join(image_path, img_metadata['rootfs']),
            '-drive', f'file={vda},if=none,id=virtio-disk0',
            '-device', 'virtio-blk-pci,drive=virtio-disk0',
            '-virtfs', f'local,path={config_dir},mount_tag=host-shared,readonly=off,security_model=mapped,id=virtfs0',
	        '-device', f'vhost-vsock-pci,guest-cid={cid}',
        ]

        # Add network configuration
        port_args = []
        for port_map in manifest.get('port_map', []):
            protocol = port_map.get('protocol', 'tcp')
            bind_address = port_map.get('address', '127.0.0.1')
            host_port = port_map['from']
            vm_port = port_map['to']
            port_args.append(f"hostfwd={protocol}:{bind_address}:{host_port}-:{vm_port}")
        cmd.extend([
            '-device', 'virtio-net-pci,netdev=nic0_td',
            '-netdev', f"user,id=nic0_td{','+','.join(port_args) if len(port_args) > 1 else ''}"
        ])

        if gpus:
            cmd.extend([
                '-device', f'pcie-root-port,id=pci.1,bus=pcie.0',
                '-fw_cfg', 'name=opt/ovmf/X-PciMmio64,string=262144',
            ])
            # Use sudo when GPU is involved
            cmd = ['sudo'] + cmd
        for i, gpu_id in enumerate(gpus):
            cmd.extend([
                '-object', f'iommufd,id=iommufd{i}',
                '-device', f'vfio-pci,host={gpu_id},bus=pci.1,iommufd=iommufd{i}',
            ])
        # Add kernel command line
        cmd.extend(['-append', img_metadata['cmdline']])

        print(" ".join(cmd))
        # Run the command
        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Failed to start VM: {e}")


def list_available_gpus() -> None:
    """List available NVIDIA GPUs."""
    try:
        result = subprocess.run(['lspci'], capture_output=True, text=True)
        gpu_lines = [line for line in result.stdout.split('\n') if 'NVIDIA' in line]
        if gpu_lines:
            print("\nAvailable GPU IDs:")
            print("ID      Description")
            for line in gpu_lines:
                print(line)
            print()
    except subprocess.SubprocessError:
        logger.warning("Could not list GPU devices")


def main():
    parser = argparse.ArgumentParser(description='DStack VM Management Tool')
    subparsers = parser.add_subparsers(dest='command', help='Commands')

    # Setup command
    setup_parser = subparsers.add_parser('new', help='Setup a new instance')
    setup_parser.add_argument('compose_file', type=str, help='Docker compose file')
    setup_parser.add_argument('-o', '--dir', type=str, help='Work directory')
    setup_parser.add_argument('-i', '--image', type=str, help='VM image path')
    setup_parser.add_argument('-c', '--vcpus', type=int, default=1, help='Number of vCPUs')
    setup_parser.add_argument('-m', '--memory', type=str, default='1G', help='Memory size (e.g., 1G, 512M)')
    setup_parser.add_argument('-d', '--disk', type=str, default='20G', help='Disk size (e.g., 20G)')
    setup_parser.add_argument('-g', '--gpu', type=str, action='append', help='GPU device')
    setup_parser.add_argument('-p', '--port', action='append', type=str, help='Port mapping in format: protocol[:address]:from:to')
    setup_parser.add_argument('--no-fde', action='store_true', help='Disable Full Disk Encryption')

    # Start command
    start_parser = subparsers.add_parser('run', help='Start an instance')
    start_parser.add_argument('dir', type=str, help='Work directory')
    start_parser.add_argument('-m', '--memory', type=str, help='Memory size (e.g. 2G, 512M)')
    start_parser.add_argument('-c', '--vcpus', type=int, help='Number of virtual CPUs')

    # List Gpus command
    subparsers.add_parser('lsgpu', help='List available GPUs')

    args = parser.parse_args()

    if args.command == 'new':
        manager = DStackManager()
        manager.setup_instance(args)
    elif args.command == 'run':
        manager = DStackManager()
        manager.run_instance(args.dir, memory=args.memory, vcpus=args.vcpus)
    elif args.command == 'lsgpu':
        list_available_gpus()
    else:
        parser.print_help()

if __name__ == '__main__':
    main()