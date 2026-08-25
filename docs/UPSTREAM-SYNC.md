# Staying in sync with upstream

The point of this fork is to be easy to compare with
[MorseMicro/morse_driver](https://github.com/MorseMicro/morse_driver) and easy to
delete. Everything below assumes these remotes:

```sh
git remote add origin   https://github.com/alan-sun-dev/morse_driver.git
git remote add upstream https://github.com/MorseMicro/morse_driver.git
git fetch upstream --tags
```

`main` is byte-identical to `upstream/main` and must stay that way. All fork
content lives on `rpi-stock-kernel-portability`.

## Taking a new upstream release

```sh
git fetch upstream --tags
git checkout main
git merge --ff-only upstream/main      # fails loudly if main ever diverged
git push origin main
```

Then move the portability work onto it:

```sh
git checkout rpi-stock-kernel-portability
git rebase main
```

Check that the rebase changed nothing but context:

```sh
git range-diff main@{1}..rpi-stock-kernel-portability@{1} main..rpi-stock-kernel-portability
```

Every commit should report `=` (unchanged) or show only line-number shifts. A
real content change there means upstream edited one of the same sites, which is
worth reading before continuing.

Push the rebased branch as a new branch or with an explicit force to a branch
only this fork uses. Never force-push `main`, and never rewrite
`fix/spi-cs-mode-and-transaction-delays` — that is the branch behind
[upstream PR #16](https://github.com/MorseMicro/morse_driver/pull/16) and it is
kept exactly as posted.

`portability-mm6108-2.0.1` is pinned to the release that was validated on
hardware. It does not get rebased; it is a fixed reference point.

## Has upstream already fixed one of these?

Run these after every upstream release. Each check is paired with a positive
control — a pattern that must match — so that a zero result means "absent"
rather than "the search was wrong".

```sh
git fetch upstream --tags
REL=upstream/main          # or a tag: REL=mm6108-2.1.0
git show $REL:spi.c > /tmp/upstream-spi.c
grep -c 'morse_spi_initsequence' /tmp/upstream-spi.c   # positive control: must be >= 2
```

**Change 1 — the `-Werror` build failure.** Obsolete when the `#else` branch no
longer raises a `#warning`:

```sh
grep -n -A3 '#ifdef SPI_CONTROLLER_ENABLE_CS_GPIOD' /tmp/upstream-spi.c
grep -c '#warning "SPI_CONTROLLER_ENABLE_CS_GPIOD macro not defined"' /tmp/upstream-spi.c
```

`0` for the second command means upstream has dealt with it — read the
replacement before dropping our commit, because removing the `#warning` and
removing `-Werror` from `ccflags-y` are different fixes with different
consequences.

The other way this becomes obsolete is from the kernel side, if a distribution
kernel starts defining the flag. Check the kernel you are building against, again
with a control:

```sh
H=$(find /usr/src -maxdepth 1 -name 'linux-headers-*' \
      -exec test -f '{}/include/linux/spi/spi.h' \; -print | head -1)/include/linux/spi/spi.h
grep -c SPI_CONTROLLER_ENABLE_CS_GPIOD "$H"   # 0 on every stock kernel tested here
grep -c SPI_CS_HIGH "$H"                      # positive control: must be 3, not 0
```

Do not shorten that to `/lib/modules/$(uname -r)/build/include/linux/spi/spi.h`.
On Raspberry Pi OS the headers are split, and `build` points at the
architecture-specific package while `spi.h` lives in the `-common-rpi` one. The
short path does not exist, `grep` reports "No such file or directory" on stderr
and prints nothing, and a count read from that is an empty string that looks like
zero. Measured on both tested kernels with the path above: **0 occurrences of the
flag, 3 of `SPI_CS_HIGH`**.

**Change 2 — the training burst with chip select asserted.** Obsolete when
`morse_spi_initsequence()` stops relying on an `SPI_CS_HIGH` flip:

```sh
sed -n '/static void morse_spi_initsequence/,/^}/p' /tmp/upstream-spi.c |
  grep -nE 'SPI_NO_CS|SPI_CS_HIGH'
```

`SPI_NO_CS` present means the fix has landed in some form. `SPI_CS_HIGH` alone
means it has not, whatever the release notes say — this is the change most likely
to be re-implemented differently, so compare behaviour rather than text.

**Change 3 — the inter-transaction delay floor.** Obsolete when the computed byte
counts have a lower bound:

```sh
grep -nE 'MIN_DELAY|max_t\(u32,[^)]*inter_block_delay|inter_block_delay_bytes =' /tmp/upstream-spi.c
```

There are three sites: the `cmd53_read` scaling, the `cmd53_write` post-write
padding, and the two places `inter_block_delay_bytes` is computed. All three need
a floor; upstream fixing one is not enough, and this is the change where a
partial adoption is most likely to look complete.

## When a change becomes obsolete

Drop the commit rather than keeping a no-op:

```sh
git rebase --onto <commit>^ <commit> rpi-stock-kernel-portability
```

Then rebuild and retest on hardware before publishing — an upstream fix that
looks equivalent is not evidence that it behaves equivalently, and the three
defects here compound: fixing one moves the failure into the next.

Record what was dropped and against which release in the README table, so the
fork's shrinking is visible rather than silent.
