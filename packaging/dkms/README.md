# DKMS packaging

A minimal packaging layer. **Upstream's Makefile is not modified** — it already
builds out-of-tree with `-C $(KERNEL_SRC) M=$(SRC)` and takes every option from
the command line, which is all DKMS needs.

```
packaging/dkms/
  dkms.conf.in        template; @VERSION@ is substituted at staging time
  prepare-source.sh   populates the submodule, stages /usr/src/morse-<version>,
                      writes dkms.conf
  README.md           this file
```

```sh
sudo packaging/dkms/prepare-source.sh
sudo dkms add    morse/<version>
sudo dkms build  morse/<version>
sudo dkms install morse/<version>      # see "install" below before running this
```

`dkms` lives in `/usr/sbin`, which is not on a non-root `PATH` on Debian — call
it through `sudo`, or `command not found` will look like a missing package.

## Status: full lifecycle validated on hardware

Run on the MM6108A2 board, kernel `6.12.96+rpt-rpi-v8`, 2026-08-25:

| | |
|---|---|
| `dkms add` | ok |
| `dkms build` | ok — `morse/mm8108-2.0.0+rpi-portability, 6.12.96+rpt-rpi-v8, aarch64: built` |
| artefacts | `morse.ko.xz`, `dot11ah.ko.xz` under `.../aarch64/module/` |
| same code as a manual build? | yes — `srcversion 89A7C1DAC9B51F941EFC8F2`, identical |
| `dkms install` | not run in that first pass — both boards were mid-soak |

**Superseded on 2026-08-25:** a full lifecycle — add, build, install, cold boot,
HaLow, kernel upgrade, automatic rebuild, cold boot, HaLow again, uninstall,
rollback — then ran end to end on a dedicated card in the A2 board. All ten legs
passed. Details and the two findings that came out of it are in
[the protocol](https://github.com/alan-sun-dev/halow-wm6108-rpi4/tree/main/tools/dkms-lifecycle).

**Two differences from a manual build, both worth knowing before trusting the
package:**

- **DKMS strips the modules.** `readelf -S` finds **0** debug sections in the
  DKMS artefact against **15** in the manual build of the same commit;
  uncompressed that is 829 KB against 26.6 MB. The driver's `DEBUG=y` default
  compiles with `-g`, and DKMS then strips it back out. Fine for running,
  unhelpful the day something needs a symbolised oops.
- **DKMS signs them**, generating `/var/lib/dkms/mok.key` on first use. Harmless
  on a Raspberry Pi, but it is a new key appearing on the machine.

The artefacts are `.ko.xz`, not `.ko` — a `find -name '*.ko'` finds nothing and
looks like a failed build.

The submodule path that `prepare-source.sh` exists for was exercised from a
genuinely fresh clone: `mmrc.h` absent after `git clone`, the script cloned
`mmrc-submodule` at the pinned `24f6c69`, and the staged tree had the header.

## DKMS v1 — frozen behaviour

The lifecycle run of 2026-08-25 is the first validated DKMS implementation, and
these four things are now fixed. Change them only with a reason and a re-run.

| | |
|---|---|
| `AUTOINSTALL` | `"yes"` — intended, and validated across a real kernel upgrade |
| `-Werror` | unchanged from upstream. Not to be weakened to get a future build to pass |
| install path | `/lib/modules/<kernel>/updates/dkms/` |
| module set | `morse` **and** `dot11ah`, both installed, `depmod` run |

**On the install path:** `dkms.conf` sets `DEST_MODULE_LOCATION="/updates"` and
Debian's dkms ignores it, normalising everything to `updates/dkms/`. That is
**observed behaviour on dkms 3.0.10, not an error** — the path lands in
`modules.dep`, `depmod` runs, and the modules load and autoload correctly. Do not
try to force the other path. The only practical consequence is for anyone who
also has hand-installed modules in `updates/` directly: two candidates for the
same module then exist, and which one loads is not something to leave to chance.
A machine should use one mechanism or the other.

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

The combination validated on hardware, and the one `dkms.conf.in`
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

## Autoinstall, `-Werror`, and one dkms surprise

`ccflags-y += $(DEBFLAGS) -Wall -Werror` — **unchanged from upstream, on
purpose.** It is the reason the first change in this fork exists at all: a
`#warning` that `-Werror` turns into a fatal error on a stock kernel.

`AUTOINSTALL="yes"`, and that is now the validated behaviour rather than a
default nobody tested. On 2026-08-25 a kernel upgrade from `6.6.51` to `6.12.96`
rebuilt and installed this module unattended from the kernel postinst, for both
the `-v8` and `-2712` flavours, and the radio associated on the first attempt
after the reboot.

**The surprise worth knowing before you edit that line:** with dkms 3.0.10 the
off value is not `"no"`. From `/usr/sbin/dkms`:

```sh
# if the module does not want to be autoinstalled, skip it.
if [[ ! $AUTOINSTALL ]]; then
    continue
fi
```

That is a test for **empty**. Every non-empty string is truthy, so `"no"` enables
autoinstall exactly as `"yes"` does. To genuinely disable it the variable must be
absent or empty, and then every kernel change needs an explicit
`dkms install -k <kernelrelease>`.

**The residual risk is unchanged and is real:** a build that fails on some future
kernel leaves the machine with no driver at the next boot, silently, during an
unattended upgrade. The answer is not to disable autoinstall — it is to verify
the upgrade before rebooting into it. The gate is in
[the lifecycle protocol](https://github.com/alan-sun-dev/halow-wm6108-rpi4/tree/main/tools/dkms-lifecycle):
dpkg clean, `modules.dep` and headers present for the new kernel, DKMS reporting
both modules installed for it, and `modinfo -k` confirming filename, srcversion
and vermagic — all before the reboot, not after.

## What DKMS does not cover

Three things this driver needs that are not modules and are out of DKMS's scope:

- the **device tree overlay** for the carrier board;
- the **BCF** and firmware in `/lib/firmware/morse/`;
- `/etc/modprobe.d/` options — at minimum `country=` and `bcf=`, plus
  `macaddr_suffix=` on the HT-HC01P, without which the driver invents a random
  MAC on every load.

A useful Raspberry Pi installer would carry those alongside the DKMS package.
That is the natural next packaging step and is deliberately not started here.

## Still to do

The MM6108**A1** hardware: the lifecycle ran on the A2 HAT only. A `debian/`
layer, so the package ships alongside the overlay, BCF and modprobe options —
none of which DKMS covers. And a deliberate test of the failure case that
`AUTOINSTALL="yes"` exposes: make a build fail on purpose for a new kernel and
confirm the gate in the protocol catches it before the reboot.
