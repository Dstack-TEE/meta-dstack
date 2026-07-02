# Yocto support for dstack guest OS

This project implements Yocto layer and the overall build scripts for dstack Base OS image.

## Build

See https://github.com/Phala-Network/dstack-cloud for more details.

## End-to-end smoke stack

After building guest images and host binaries, use the e2e helper to bring up a
complete local dstack stack (KMS, gateway, VMM, and multiple app CVMs):

```bash
./e2e/run.sh up --image dstack-0.6.0 --apps 3
```

See [`e2e/README.md`](e2e/README.md) for prerequisites, overrides, log access,
and teardown commands.

## Reproducible Build The Guest Image

### Pre-requisites

- X86_64 Linux system with Docker installed

### Build commands

```bash
git clone https://github.com/Dstack-TEE/meta-dstack.git
cd meta-dstack/repro-build/
./repro-build.sh
```

## License

See the LICENSE file for more details.
