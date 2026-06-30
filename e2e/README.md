# dstack e2e stack

`e2e/run.sh` brings up a complete local dstack stack from built guest images:

- one KMS
- one dstack-gateway
- one VMM
- N app CVMs (default: 2) running a tiny BusyBox HTTP app

Runtime files live in `build/e2e/` by default, so the repository stays clean.

## Prerequisites

1. Build guest images, for example:

   ```bash
   cd build
   ../build.sh guest
   ```

2. Build host binaries if they are not already available:

   ```bash
   ./build.sh host
   ```

   Or let the e2e script do that when binaries are missing:

   ```bash
   E2E_BUILD_HOST=1 ./e2e/run.sh up
   ```

3. The host must be able to run dstack CVMs (KVM/TDX or SEV-SNP as appropriate).
   Gateway needs WireGuard privileges; if not run as root, the script uses
   passwordless `sudo` for the gateway process.

## Run

```bash
./e2e/run.sh up --image dstack-0.6.0 --apps 3
```

If `--image` is omitted, the script picks the latest non-NVIDIA `dstack-*` image
under `build/images/`.

The script starts services, deploys app CVMs, waits for each HTTP app through a
host port mapping, and also checks the same app through dstack-gateway.

Useful follow-ups:

```bash
./e2e/run.sh status
./e2e/run.sh smoke
./e2e/run.sh logs
./e2e/run.sh down
```

For a CI-style run that tears down after success:

```bash
./e2e/run.sh up --cleanup
```

## KMS mode

The e2e helper runs KMS as a local dev service, with self-authorization disabled
and dev-only certificate material generated under the work directory. App key
release is still exercised against app CVM attestation when app KMS is enabled,
but this is not a production KMS deployment recipe.

To exercise KMS OS-image verification, including the TDX path that should not
need the QEMU-derived `dstack-acpi-tables` helper in the KMS runtime:

```bash
./e2e/run.sh up --image dstack-0.6.0 --apps 1 --kms-image-verify --kms-no-qemu
```

For legacy verification, `--kms-image-verify` pre-populates the local KMS image
cache with the `digest.txt` hash. With `--kms-no-qemu`, the lite path
intentionally skips that cache pre-population so KMS cannot rely on a downloaded
image. It starts only the KMS process with a restricted `PATH`
(`/usr/sbin:/usr/bin:/sbin:/bin`) and asks the VMM to launch app CVMs with
`tdx_attestation_variant = "lite"`.

The no-image-download TDX lite path supports app memory of exactly
2048 MiB or at least 2816 MiB. QEMU's patched kernel Authenticode hash is
memory-dependent for other low-memory sizes, while exactly 2 GiB produces the
same patched kernel bytes as the high-memory placement. Legacy TDX attestation
remains the default (`tdx_attestation_variant = "legacy"`), so the existing
digest.txt + full legacy verifier path is unchanged unless this vm_config mode
is selected.

## Common overrides

```bash
E2E_APP_COUNT=4 ./e2e/run.sh up
E2E_IMAGE=dstack-dev-0.6.0 ./e2e/run.sh up
E2E_TEE_PLATFORM=amd-sev-snp ./e2e/run.sh up
E2E_QEMU_PATH=/usr/local/bin/qemu-system-x86_64 ./e2e/run.sh up
```

For infra debugging on a non-TEE machine, you can start app VMs with `--no-tee`.
In that mode you usually also want to skip app KMS key release:

```bash
./e2e/run.sh up --no-tee --no-app-kms --no-app-gateway
```

This still starts KMS and Gateway services, but it is not a full confidential-VM attestation or gateway-registration test.
