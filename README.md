# morse_driver — Raspberry Pi OS portability fork

**Independent community fork of [MorseMicro/morse_driver](https://github.com/MorseMicro/morse_driver)
focused on stock Linux / Raspberry Pi OS SPI portability for MM6108. This is not
an official Morse Micro release.**

Morse Micro owns the driver, the trademark and the upstream repository. Nothing
here is endorsed by them. The fork exists for one reason: the released driver
does not build or run on a stock Raspberry Pi OS kernel over SPI, and three small
changes to `spi.c` make it do both. Upstream's own build notes remain in
[`README`](README).

The delta against upstream is **one file, 62 insertions and 8 deletions**. It is
meant to stay that small, and to disappear entirely if Morse Micro adopt the
fixes.

## Relationship to upstream

| Branch | Base | Contents |
|---|---|---|
| `main` | — | byte-identical to `upstream/main`. Never diverges; fast-forward only |
| `rpi-stock-kernel-portability` | `upstream/main` (`a76cb32`, release `mm8108-2.0.0`) | the three portability commits + this documentation |
| `portability-mm6108-2.0.1` | tag `mm6108-2.0.1` (`98e1936`) | the same three commits on the release that was validated on hardware |

Both fix branches carry the identical `spi.c` change. They differ only by
upstream's own edits to `spi.c` between the two releases
(`XTAL_TRANSFER_DELAY_BYTES`, and a reset delay simplification) — neither touches
the areas this fork changes.

The same three commits are also open upstream as
[MorseMicro/morse_driver#16](https://github.com/MorseMicro/morse_driver/pull/16).
The branch behind that PR (`fix/spi-cs-mode-and-transaction-delays`) is kept as
posted and is not modified.

## What the three changes do

All three are in `spi.c`. None adds a module parameter, changes a default, or
touches any other bus.

**1. `spi: do not fail the build when SPI_CONTROLLER_ENABLE_CS_GPIOD is absent`**

`SPI_CONTROLLER_ENABLE_CS_GPIOD` is a vendor-kernel flag. Where it is missing the
driver raises `#warning`, and `ccflags-y` carries `-Werror`, so the build fails
outright. Counted directly in both tested kernels: **zero occurrences in
`include/linux/spi/spi.h`**. A kernel without the flag already forces
`SPI_CS_HIGH` for a `cs-gpios` device, which is the behaviour the flag existed to
obtain, so the `#else` branch becomes a comment.

**2. `spi: put the chip into SPI mode on cs-gpios controllers`**

MM6108 needs roughly 74 clocks with chip select **deasserted** before it enters
SPI mode. `morse_spi_initsequence()` arranges that by flipping `SPI_CS_HIGH`, but
on a `cs-gpios` controller `spi_setup()` forces the bit straight back on, so the
training burst goes out with the chip selected. Every response afterwards sits
two bit times off the byte grid (`c0 7f` where `01 ff` is expected) and probe
fails at CMD63 with `-EPROTO`. The fix uses `SPI_NO_CS` for the burst and
restores the previous mode, keeping the old flip as a fallback for controllers
that do not support `SPI_NO_CS`.

Ordering matters: the burst must come after reset and before any other
transaction.

**3. `spi: floor the inter-transaction delays at 250 bytes`**

The delays are derived from a time and converted to a byte count with the SPI
clock — 250 bytes at 50 MHz, 50 bytes at 10 MHz, both 40 µs. Measured: 250 works
and 50 fails at the same 40 µs, so the chip counts clocks, not microseconds, and
the existing model only lands on a working value at full clock. Three sites are
floored at 250 and all three are independently necessary. The same floor already
exists in Morse's OpenWrt feed (`003_fix_spi_inter_transaction_delay.patch`) but
not in the released driver.

## Tested

Measured on hardware with the `portability-mm6108-2.0.1` tree — driver release
`mm6108-2.0.1` plus these three commits — loaded with no module parameters beyond
`country=`, `bcf=` and, on the HT-HC01P, `macaddr_suffix=`.

| Kernel (Raspberry Pi OS bookworm) | MM6108**A1** — Wio-WM6108 on a SenseCAP M1 SPI carrier | MM6108**A2** — Heltec HT-HC01P Pi HAT |
|---|---|---|
| `6.6.51+rpt-rpi-v8` | associated, traffic, `errors 0` | associated, traffic, `errors 0` |
| `6.12.96+rpt-rpi-v8` | not tested | associated, traffic, `errors 0` |

What "associated, traffic" covers on each: firmware and the board's own BCF load,
WPA3-SAE with PMF, DHCP over the air, bidirectional traffic, and the SPI core's
own counters reporting `errors 0` / `timedout 0`. The Wio-WM6108 was validated at
both 10 MHz and 50 MHz SPI; the HT-HC01P at the 50 MHz its vendor device tree
specifies, with the AP rating the link MCS7 at 4 MHz.

Unpatched `mm6108-2.0.1` **fails to build** on both kernels, with the identical
`spi.c` `-Werror=cpp` error.

Not tested: MM8108, SDIO, USB, mesh, CSA, and power save with the WAKE/BUSY
handshake — the last of these is disabled on every board here rather than
exercised.

The `rpi-stock-kernel-portability` branch is **build-tested only**. Its base is a
different upstream release from the one that ran on hardware; see the build
status in [`docs/UPSTREAM-SYNC.md`](docs/UPSTREAM-SYNC.md).

## Evidence

The measurements, logs, failure traces and the reasoning behind each change live
in the research repository, not here:

**https://github.com/alan-sun-dev/halow-wm6108-rpi4**

That repository also holds what is specific to a board rather than to the driver,
and which this fork deliberately does not carry:

- **Device tree.** Each carrier needs its own overlay. The SenseCAP M1 wiring and
  the Heltec HAT pinout differ, and on Raspberry Pi OS the HT-HC01P overlay must
  narrow `spi0_cs_pins` to `<8>` — the stock `<8 7>` steals GPIO 7, which is
  MM_BUSY on that HAT.
- **BCF.** The board config file is per board, and loading the wrong one leaves
  the module receiving normally while transmitting nothing.
- **Firmware.** From `MorseMicro/morse-firmware`; not redistributed here.

## Building

Against the running kernel on a Raspberry Pi, with the kernel headers installed:

```sh
git clone -b rpi-stock-kernel-portability https://github.com/alan-sun-dev/morse_driver.git
cd morse_driver
git submodule update --init --recursive        # see the note below
make KERNEL_SRC=/lib/modules/$(uname -r)/build \
     CONFIG_WLAN_VENDOR_MORSE=m CONFIG_MORSE_SPI=y \
     CONFIG_MORSE_USER_ACCESS=y CONFIG_MORSE_VENDOR_COMMAND=y \
     CONFIG_MORSE_DEBUGFS=y -j4
sudo install -m 644 morse.ko dot11ah/dot11ah.ko /lib/modules/$(uname -r)/updates/
sudo depmod -a
```

**Submodule note.** `.gitmodules` uses a relative URL (`../mm_rate_control.git`),
which resolves against whichever account the clone came from — so in a fork it
points at a repository that does not exist. Until that is addressed, override it
once per clone:

```sh
git config submodule.mmrc-submodule.url https://github.com/MorseMicro/mm_rate_control.git
git submodule sync && git submodule update --init --recursive
```

Without the submodule the build fails on a missing `mmrc.h`, which looks
unrelated to the real cause.

## Licence and attribution

Upstream is GPL-2.0-or-later and stays that way. Upstream copyright notices, file
headers and author attribution are preserved unchanged; no upstream-derived file
is relicensed. The three commits touch `spi.c` only and add no new source file.
Documentation added by this fork is offered under the same terms.

Upstream carries no `CONTRIBUTING` file and no DCO: all eleven upstream commits
are release drops from `Morse Micro <info@morsemicro.com>` and none carries a
`Signed-off-by`. The commits here therefore carry none either. A `Signed-off-by`
is a certification the author makes personally and can be added if upstream ever
asks for one.

## Maintenance

See [`docs/UPSTREAM-SYNC.md`](docs/UPSTREAM-SYNC.md) for the rebase workflow and
for how to check whether a new Morse release has already fixed any of this — the
point at which the corresponding commit should be dropped.

DKMS packaging is assessed but not implemented; see
[`packaging/dkms/README.md`](packaging/dkms/README.md).
