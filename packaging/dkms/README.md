# DKMS packaging — assessment and proposal

**Nothing here is wired up.** This directory documents what DKMS packaging of
this driver would require and ships a proposed `dkms.conf.proposed`. It has not
been built, installed or tested, and no file here is picked up by DKMS as things
stand — `dkms add` looks for `dkms.conf` at the root of the source tree it is
given, not in a subdirectory.

The reason for stopping here is that DKMS's value is in surviving kernel
upgrades unattended, and this driver has a property that makes that risky; see
"The `-Werror` problem" below.

## Verdict

DKMS can be added **as a small packaging layer, without restructuring upstream's
Makefile**. The Makefile already does the two things DKMS needs: it builds
out-of-tree with `-C $(KERNEL_SRC) M=$(SRC)`, and it takes every option from the
command line rather than from a `.config`. Nothing about it has to change.

Three things do have to be handled by the packaging layer, and two of them are
easy to get wrong.

## What must be installed

Two modules, from one source tree:

| Module | Built at | Installs to |
|---|---|---|
| `morse.ko` | tree root | `updates/` |
| `dot11ah.ko` | `dot11ah/` | `updates/` |

`morse` uses symbols exported by `dot11ah`, so both must be installed and
`depmod` run. Installing only `morse.ko` produces `Unknown symbol` at load time.

## Required build variables

The combination validated on hardware, and the one the proposed `dkms.conf`
carries:

```
CONFIG_WLAN_VENDOR_MORSE=m
CONFIG_MORSE_SPI=y
CONFIG_MORSE_USER_ACCESS=y
CONFIG_MORSE_VENDOR_COMMAND=y
CONFIG_MORSE_DEBUGFS=y
KERNEL_SRC=${kernel_source_dir}
```

`CONFIG_MORSE_SDIO=y` and `CONFIG_MORSE_USB=y` are the obvious additions for
other buses. Neither has been tested here, and adding a bus adds a source file to
the build, so a package that offers all three should be built and loaded once per
bus before it is published.

`MORSE_TRACE_PATH` is **not optional**: `trace.h` has

```c
#ifndef MORSE_TRACE_PATH
#error "MORSE_TRACE_PATH must be defined"
```

The Makefile defaults it to `.`, which resolves against the build directory. That
default is what the validated builds used, and it works. Under DKMS the build
happens in `/var/lib/dkms/<name>/<version>/build`, so the default should still be
correct — but it is a relative path fed to `TRACE_INCLUDE_PATH`, and it is the
first thing to check if a DKMS build fails where a manual build succeeds.

## Submodule handling — the trap

`mmrc-submodule` (`MorseMicro/mm_rate_control`, pinned at `24f6c69`) contributes
`mmrc-submodule/src/core/mmrc.o` to `morse-y` unless `CONFIG_DISABLE_MORSE_RC=y`.

**DKMS does not know about git.** It copies a source directory to
`/usr/src/<name>-<version>` and builds from there. If the submodule is not
populated at that point the build fails on a missing
`mmrc-submodule/src/core/mmrc.h`, which reads as an unrelated error.

So the packaging step must, before handing the tree to DKMS, either

- run `git submodule update --init --recursive` and copy the populated tree, or
- vendor the submodule contents into the package source.

A source tarball produced by `git archive` **does not include submodules** and
will fail this way. This fork also changed `.gitmodules` to an absolute URL,
because the upstream relative URL does not resolve from a fork at all; see the
commit message on that change.

The alternative is `CONFIG_DISABLE_MORSE_RC=y`, which drops the submodule and
uses `minstrel_rc.o` instead. That changes rate-control behaviour and has not
been tested here.

## Kernel header dependency

`raspberrypi-kernel-headers` on Raspberry Pi OS, or `linux-headers-$(uname -r)`
generally. The 2024-11-19 Raspberry Pi OS image already ships matching headers for
both `6.6.51+rpt-rpi-v8` and, after an upgrade, `6.12.96+rpt-rpi-v8`; nothing had
to be transplanted for either build.

## The `-Werror` problem

`ccflags-y += $(DEBFLAGS) -Wall -Werror`.

Under DKMS with `AUTOINSTALL="yes"`, the driver is rebuilt automatically whenever
a new kernel is installed. With `-Werror`, any new warning introduced by a newer
kernel's headers is a build failure, and it happens during an unattended
`apt upgrade` — the module silently stops being available at the next boot. This
is not hypothetical for this driver: the whole reason the first change in this
fork exists is a `#warning` that `-Werror` turned into a fatal error on a stock
kernel.

Options, none of them free:

1. Keep `-Werror` and set `AUTOINSTALL="no"`, so a kernel upgrade leaves the old
   module and a human decides when to rebuild. Safest, least convenient.
2. Keep `-Werror` and `AUTOINSTALL="yes"`, and accept that a kernel upgrade can
   remove the driver.
3. Drop `-Werror` in the DKMS build only. This diverges from how the driver is
   built everywhere else, including how it was validated, so warnings would go
   unnoticed in exactly the builds nobody watches.

The proposal below takes option 1 and says so in a comment. This should be an
explicit decision, not a default.

## What DKMS does not cover

Three things this driver needs that are not modules and are out of DKMS's scope:

- the **device tree overlay** for the carrier board;
- the **BCF** and firmware in `/lib/firmware/morse/`;
- `/etc/modprobe.d/` options — at minimum `country=` and `bcf=`, plus
  `macaddr_suffix=` on the HT-HC01P, without which the driver invents a random
  MAC on every load.

A useful Raspberry Pi installer would carry those alongside the DKMS package.
That is the natural next packaging step and is deliberately not started here.

## Proposed layout

```
packaging/dkms/
  README.md              this assessment
  dkms.conf.proposed     draft, untested; would be installed as
                         /usr/src/morse-<version>/dkms.conf
```

Left for later, once the above decisions are made: a `prepare-source.sh` that
populates the submodule and stages `/usr/src/morse-<version>`, and optionally a
`debian/` layer.
