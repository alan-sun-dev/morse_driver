# Release candidate notes — DRAFT

**Proposed version: `mm8108-2.0.0-rpi-portability.1`**

**Nothing has been tagged or published.** This file is the draft that a first
community release candidate would be cut from. No git tag, no GitHub Release, no
announcement anywhere. Read it as a proposal.

The version names what it is: upstream release `mm8108-2.0.0`, plus this fork's
portability delta, revision 1.

---

## What this is

An independent community fork of
[MorseMicro/morse_driver](https://github.com/MorseMicro/morse_driver) focused on
stock Linux / Raspberry Pi OS SPI portability for MM6108. **It is not an official
Morse Micro release**, it is not endorsed by Morse Micro, and it claims no
ownership of their driver. Morse Micro own the driver, the trademark and the
upstream repository.

The delta against upstream is **one source file** — `spi.c`, 62 insertions and 8
deletions — plus one line of `.gitmodules`, documentation, and a DKMS packaging
layer. It is meant to stay that small and to disappear if the fixes are adopted
upstream.

## What is in it

Three changes to `spi.c`, all previously submitted upstream as
[PR #16](https://github.com/MorseMicro/morse_driver/pull/16):

1. **the driver builds on a stock kernel** — `SPI_CONTROLLER_ENABLE_CS_GPIOD` is
   a vendor-kernel flag, and its absence raised a `#warning` under `-Werror`,
   which is fatal. Counted directly: 0 occurrences in both tested kernels'
   `include/linux/spi/spi.h`.
2. **the chip is put into SPI mode on `cs-gpios` controllers** — the ~74 training
   clocks need chip select deasserted, and `spi_setup()` undoes the `SPI_CS_HIGH`
   flip the driver relies on. Uses `SPI_NO_CS` for the burst, with the old flip
   kept as a fallback.
3. **inter-transaction delays are floored at 250 bytes** — the delay is a clock
   count, not an interval, and the existing model only produces a working value
   at 50 MHz.

One packaging change outside `spi.c`: `.gitmodules` uses the absolute upstream
URL for `mmrc-submodule`, because the relative URL upstream ships cannot resolve
from any fork.

Plus: a DKMS layer under `packaging/dkms/`, `docs/UPSTREAM-SYNC.md`, and this
file. Upstream's own `README` and build system are untouched, `-Werror` included.

## Validation

See the matrix in [`README.md`](README.md). In short: MM6108A1 validated on
6.6.51; MM6108A2 validated on 6.6.51 and 6.12.96; the A1 board on 6.12.96 is
**not tested**. A full DKMS lifecycle — install, cold boot, HaLow, kernel upgrade
with automatic rebuild, boot, HaLow again, uninstall, rollback — passed on the A2
board.

**Not every permutation has been tested, and the matrix says which.**

## Known limitations

- **MM6108 only.** MM8108 is untested here despite the version string naming that
  release; see the README section on what that string is.
- **SPI only.** SDIO and USB are untouched and untested by this fork.
- **The A1 board has not run 6.12.96**, and the DKMS lifecycle has not been run
  on A1 hardware at all.
- **Mesh, CSA and 802.11s are not exercised.** No claim is made about them.
- **Power save is untested.** The WAKE/BUSY handshake has never been exercised on
  2.0.1; power save is disabled on every board here rather than validated.
- **`-Werror` is retained deliberately**, and with DKMS `AUTOINSTALL="yes"` that
  means a build which fails on some future kernel leaves no driver at the next
  boot. The mitigation is the pre-reboot gate, not weakening the flag.
- **Stability is short-duration only.** The A1 soak has passed under sustained
  real SPI activity with error counters at zero, but that is not a long-term
  stability claim.
- **Hardware-specific pieces are not shipped here** — device tree overlay, BCF,
  firmware and `modprobe` options are per board and live in the research
  repository.

## Rollback

**If the driver is installed by hand**, keep the previous modules beside the live
ones and copy them back:

```sh
cd /lib/modules/$(uname -r)/updates/
sudo cp -a morse.ko.<previous>   morse.ko          # or .ko.xz, per image
sudo cp -a dot11ah.ko.<previous> dot11ah.ko
sudo depmod -a && sudo reboot
```

**If it is installed by DKMS**, the uninstall is the rollback and it was
validated end to end:

```sh
sudo dkms uninstall morse/<version> --all
sudo dkms remove    morse/<version> --all
sudo rm -rf /usr/src/morse-<version>
sudo reboot
```

Afterwards there should be no `morse` or `dot11ah` under any `updates/`
directory, no `morse` line in `dkms status`, and no module loaded. Verify with
`dkms-lifecycle.sh rollback-check` in the research repository — and verify it
**after a reboot**, because uninstall removes files without unloading a running
module.

**Rolling back a kernel** on Raspberry Pi OS needs explicit lines in
`config.txt`, not just a reboot, because the firmware loads
`/boot/firmware/initramfs8` regardless of which kernel you select:

```
kernel=kernel8-<version>.img
initramfs initramfs8-<version> followkernel
```

Copy those two files aside *before* the upgrade that replaces them.

## Before rebooting into a new kernel

Do not. Run the gate first — `dkms-lifecycle.sh preflight <kernelrelease>` in the
research repository checks dpkg state, the module tree, `modules.dep`, initramfs,
headers, `dkms status`, both module files and `modinfo -k` for the target kernel,
and exits non-zero if any of them is wrong. It was validated in both directions.

## Relationship to upstream

`main` in this fork is byte-identical to `upstream/main` and is fast-forward
only. All fork content lives on `rpi-stock-kernel-portability`, which is the
default branch. `fix/spi-cs-mode-and-transaction-delays` is the branch behind
upstream PR #16 and is kept exactly as posted. Upstream history is never
rewritten. Upstream is GPL-2.0-or-later; copyright notices, file headers and
author attribution are unchanged and nothing upstream-derived is relicensed.

`docs/UPSTREAM-SYNC.md` describes taking a new upstream release, and how to check
whether a release has already fixed one of these so the corresponding commit can
be dropped.

## Evidence

Measurements, logs, failure traces and the reasoning behind each change are in
the research repository, which is where they stay:

**https://github.com/alan-sun-dev/halow-wm6108-rpi4**
