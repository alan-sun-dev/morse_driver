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

## Validation matrix

Hardware validated means: built on that kernel, loaded, firmware and the board's
own BCF loaded, WPA3-SAE with PMF association, DHCP, bidirectional traffic, and
the SPI core's own counters reporting `errors 0` / `timedout 0`.

**Wio-WM6108 / MM6108A1** — SenseCAP M1 SPI carrier

| kernel | status |
|---|---|
| Raspberry Pi OS `6.6.51+rpt-rpi-v8` | **hardware validated** |
| Raspberry Pi OS `6.12.96+rpt-rpi-v8` | not tested |

**Heltec HT-HC01P / MM6108A2** — Heltec Raspberry Pi HAT

| kernel | status |
|---|---|
| Raspberry Pi OS `6.6.51+rpt-rpi-v8` | **hardware validated** |
| Raspberry Pi OS `6.12.96+rpt-rpi-v8` | **hardware validated** |

**DKMS** — full lifecycle, MM6108A2 board, 2026-08-25

| stage | status |
|---|---|
| clean install on `6.6.51` | **validated** |
| cold-boot autoload | **validated** |
| automatic rebuild during kernel upgrade to `6.12.96` | **validated** |
| boot and HaLow operation after the upgrade | **validated** |
| uninstall | **validated** |
| clean rollback, no module present afterwards | **validated** |

**This is not a claim about every permutation.** Four cells of the hardware
matrix exist and three are filled; the DKMS lifecycle was exercised on the A2
board only. Anything not listed above has not been tested — including MM8108,
SDIO, USB, mesh, CSA, and power save with the WAKE/BUSY handshake, which is
disabled on every board here rather than exercised.

The Wio-WM6108 was validated at both 10 MHz and 50 MHz SPI; the HT-HC01P at the
50 MHz its vendor device tree specifies, with the AP rating the link MCS7 at
4 MHz. Unpatched `mm6108-2.0.1` **fails to build** on both kernels with the
identical `spi.c` `-Werror=cpp` error, and so does upstream `main`.

### The evidence behind the matrix

**Build, with its control.** Built from a fresh clone on both Raspberry Pi 4B
test machines against the running kernel's headers, and pristine `upstream/main`
built on the same machine with the same command as the control:

| kernel | this branch | pristine `upstream/main`, same machine and command |
|---|---|---|
| `6.6.51+rpt-rpi-v8` | 0 warnings, 0 errors, both modules produced | **fails** — `spi.c:1514: error: #warning "SPI_CONTROLLER_ENABLE_CS_GPIOD macro not defined" [-Werror=cpp]` |
| `6.12.96+rpt-rpi-v8` | 0 warnings, 0 errors, both modules produced | **fails** — same error, same line |

Counted in the same pass, in
`/usr/src/linux-headers-<version>+rpt-common-rpi/include/linux/spi/spi.h`:
`SPI_CONTROLLER_ENABLE_CS_GPIOD` **0 occurrences** in both kernels, against 3 for
`SPI_CS_HIGH` in the same file as a positive control.

**On hardware.** Both boards were installed to `updates/` and **cold rebooted**,
so what was exercised is the unattended autoload path, not an `insmod`:

| | MM6108A2 — HT-HC01P, `6.12.96` | MM6108A1 — Wio-WM6108, `6.6.51` |
|---|---|---|
| module autoloaded | t = 4.96 s | t = 9.96 s |
| authenticated → associated | 7.35 s → 7.41 s, **try 1/3** | 12.08 s → 12.10 s, **try 1/3** |
| security, from the AP | `auth_alg=sae`, `MFP: yes` | `auth_alg=sae`, `MFP: yes` |
| link | MCS7 / 4 MHz, `tx failed 0` | MCS7 / 4 MHz, `tx failed 0` |
| data | 4 MiB each way, SHA-256 matching | 4 MiB each way, SHA-256 matching |
| SPI | `errors 0`, `timedout 0` | `errors 0`, `timedout 0` |

That the running module was the one under test was checked rather than assumed
(`srcversion`, and the version string), the reboots were confirmed from
`/proc/sys/kernel/random/boot_id` rather than from uptime, and that the traffic
crossed the radio was established from the AP's own per-station byte counters
moving by the size of the transfers.

**One line that looks like a regression and is not:** the A1 board logs
`associating to AP … with corrupt beacon`. Counted across every boot still in its
journal it also appears on two boots that ran the previous driver, six times on
one of them, and association completed 15 ms later on the first attempt either
way.

### Soak

The A1 station has passed a **short-duration soak under sustained real SPI
activity**: 4 h 40 m on a single unbroken association, **1,521,061 SPI messages /
451 MB**, with `errors 0`, `timedout 0`, `tx failed 0` at both ends and no
failure lines in the driver log. Association uptime tracked machine uptime
throughout, so the link never re-established.

The metric here is not uptime on its own — it is that the message and byte
counters keep climbing while the error counters stay at zero. This is
deliberately not called long-term stability. Running record in the research
repository.

## Why the module reports `mm8108_2_0_0`

On this branch `modinfo morse` and `/sys/module/morse/version` both say
`0-rel_mm8108_2_0_0_2026_Apr_21`, on hardware that is an MM6108. That is correct
and it is not a chip selection. Traced end to end:

```
Makefile:11          override MORSE_VERSION = "0-rel_mm8108_2_0_0_2026_Apr_21"
Makefile:21          ccflags-y += "-DMORSE_VERSION=$(MORSE_VERSION)"
morse.h:65           #define DRV_VERSION __stringify(MORSE_VERSION)
init.c:103           MODULE_VERSION(DRV_VERSION)      -> modinfo, /sys/module/morse/version
init.c:45            pr_info("morse micro driver registration. Version %s\n", DRV_VERSION)
command.c:1106       MORSE_INFO(... "Morse Driver Version: %s, Morse FW Version: %s", DRV_VERSION, resp->version)
```

`dot11ah` has its own copy of the same literal in `dot11ah/Makefile:11`, reaching
`DOT11AH_VERSION` in `dot11ah/dot11ah.h:98`.

Those are **all** the uses — a `MODULE_VERSION`, two log lines, and nothing else.
Nothing branches on it. In particular the parsing right below `command.c:1106`
operates on `resp->version`, the string the *firmware* returns, so
`mors->sw_ver` never comes from this macro.

It is a per-release literal that Morse Micro edit at each drop:

| tag | literal |
|---|---|
| `1.17.9` | `0-rel_1_17_9_2026_Apr_20` |
| `mm6108-2.0.1` | `0-rel_mm6108_2_0_1_2026_Jun_11` |
| `mm8108-2.0.0` | `0-rel_mm8108_2_0_0_2026_Apr_21` |

So it names **the upstream release this tree came from**, and upstream `main`
currently points at `mm8108-2.0.0`. The `portability-mm6108-2.0.1` branch reports
`mm6108_2_0_1` for exactly the same reason. Changing the string would make the
module misreport its own provenance, so this fork leaves it alone.

The `override` keyword means a command line cannot change it either:

```
$ make -n MORSE_VERSION='"SET-FROM-COMMAND-LINE"' KERNEL_SRC=... all | head -1
make MORSE_VERSION="0-rel_mm8108_2_0_0_2026_Apr_21" -C ... M=...
```

**The chip is identified at run time, not by this label.** `mm6108.o` and
`mm8108.o` are both linked in unconditionally (`Makefile:138-139`); `hw.c:431`
reads `MORSE_REG_CHIP_ID` over the bus and walks `chip_series[]` calling
`chip_id_matches()`. Measured on the two boards running this branch, both of them
labelled `mm8108_2_0_0`:

| | HT-HC01P | Wio-WM6108 |
|---|---|---|
| firmware the driver loaded | `morse/mm6108.bin` | `morse/mm6108.bin` |
| `HW version` from debugfs `vendor_info` | `0x00000406` — MM6108**A2** | `0x00000306` — MM6108**A1** |
| `SW version` (from the firmware, not the driver) | 2.0.1 | 2.0.1 |

Three different version-shaped things are in play and only the first is this
macro: the **driver build label** (`mm8108_2_0_0`), the **firmware version** the
chip reports (2.0.1), and the **chip ID** read off the bus (`0x406` / `0x306`).

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

DKMS packaging exists as a minimal layer that leaves upstream's Makefile alone;
it is build-tested but not install-tested. See
[`packaging/dkms/README.md`](packaging/dkms/README.md).
