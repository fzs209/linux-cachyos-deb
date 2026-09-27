# Linux CachyOS -> Debian `.deb` GitHub Actions build

This repository structure converts the supplied CachyOS `linux-cachyos` PKGBUILD flow into a Debian `bindeb-pkg` build.

## Workflow behavior

- Manual `workflow_dispatch` lets you select `Variant`, `_processor_opt`, `_use_llvm_lto`, and an optional exact `CachyOS/linux` tag.
- An empty exact tag resolves the current `_major`, `_minor`, and `_tagrel` from the upstream `linux-cachyos/PKGBUILD` and forms `cachyos-<version>-<pkgrel>`.
- Scheduled checks run every 6 hours.
- A scheduled run always uses:
  - `Variant=linux-cachyos`
  - `_processor_opt=X86_64_V3`
  - `_use_llvm_lto=full`
- Each automatically built source release is marked with an `auto-cachyos-...` Git tag so later scheduled checks do not rebuild the same release.
- `ccache` is restored/saved through `actions/cache` and capped at 4 GiB.
- `DEBUG_KERNEL` is explicitly disabled. The supplied PKGBUILD's HZ/tick/preemption/THP/O3 choices are also reproduced.
- The package release, selected CPU optimization, Variant, and `_use_llvm_lto` mode are encoded into `kernelrelease`, e.g. `7.2.8-1-cachyos-x86-64-v3-lto-full`; `thin`, `thin-dist`, and `none` use `lto-thin`, `lto-thin-dist`, and `lto-none`. The build exports this suffix via `LOCALVERSION` and explicitly regenerates Kbuild release metadata before packaging.
- When `_use_llvm_lto=none`, no `LLVM=1` is passed to the Rust check or Debian package build.
- Ubuntu runners use debhelper 13; the generated bindeb-pkg dependency is adjusted to `debhelper-compat (= 13)` while `DH_COMPAT=12` preserves the kernel packaging compatibility level.
- The build uses LLVM for LTO builds and `make bindeb-pkg` to generate Debian packages.

## Local Debian build

Install the same build dependencies as the workflow, then run:

```bash
./scripts/build-cachyos-deb.sh linux-cachyos X86_64_V3 full cachyos-7.2.8-1
```

Leave the tag argument empty to resolve the latest upstream version:

```bash
./scripts/build-cachyos-deb.sh linux-cachyos X86_64_V3 full
```

The packages are written to `output/`.

## Installing on Debian

Copy the generated image and headers packages to the Debian machine and install them with:

```bash
sudo apt install ./linux-image-*.deb ./linux-headers-*.deb
sudo update-grub
```

Then reboot and select the new kernel in GRUB if necessary.

## Important CPU note

Do not use `NATIVE` just because the build host supports it. With GitHub-hosted runners, `NATIVE` means the kernel is optimized for the runner CPU, not necessarily for the Debian target machine. `X86_64_V3` is the portable choice used by the automatic build.

## Supported variants in this translation

The generic PKGBUILD scheduler logic is mapped to these packaging variants:

- `linux-cachyos` -> `cachyos`
- `linux-cachyos-bore` -> `bore`
- `linux-cachyos-bmq` -> `bmq`
- `linux-cachyos-eevdf` -> `eevdf`
- `linux-cachyos-hardened` -> `hardened`
- `linux-cachyos-rt-bore` -> `rt-bore`

The server/deckify/LTS/RC packages are intentionally not included in this first translation because their PKGBUILDs carry additional variant-specific configuration semantics beyond the supplied generic PKGBUILD.
