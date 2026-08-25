#!/bin/sh
# Stage this driver tree as a DKMS source tree. Nothing in the upstream build
# system is modified; this only copies and generates dkms.conf.
#
#   sudo packaging/dkms/prepare-source.sh
#   sudo dkms add    morse/<version>
#   sudo dkms build  morse/<version>
#   sudo dkms install morse/<version>      # touches /lib/modules -- see README
set -eu

SRC=$(cd "$(dirname "$0")/../.." && pwd)
TEMPLATE="$SRC/packaging/dkms/dkms.conf.in"

# The package version follows the upstream release the tree is based on, taken
# from the Makefile's own literal rather than typed in by hand. That literal is
# MORSE_VERSION, e.g. "0-rel_mm8108_2_0_0_2026_Apr_21" -> mm8108-2.0.0.
RAW=$(sed -n 's/^override MORSE_VERSION *= *"\(.*\)"/\1/p' "$SRC/Makefile")
[ -n "$RAW" ] || { echo "cannot read MORSE_VERSION from $SRC/Makefile" >&2; exit 1; }
VERSION=$(echo "$RAW" | sed -e 's/^0-rel_//' -e 's/_[0-9]\{4\}_[A-Z][a-z][a-z]_[0-9]\{2\}$//' \
                            -e 's/^\(mm[0-9]*\)_/\1-/' -e 's/_/./g')
VERSION="${VERSION}+rpi-portability"

DEST="/usr/src/morse-$VERSION"
echo "staging $SRC -> $DEST  (version $VERSION, from MORSE_VERSION=$RAW)"

# DKMS does not resolve git submodules; it copies a directory. mmrc-submodule
# must be populated here or the build dies on a missing mmrc.h.
if [ ! -f "$SRC/mmrc-submodule/src/core/mmrc.h" ]; then
    echo "populating mmrc-submodule"
    ( cd "$SRC" && git submodule update --init --recursive )
fi
[ -f "$SRC/mmrc-submodule/src/core/mmrc.h" ] || {
    echo "mmrc-submodule is still empty; the build would fail on mmrc.h" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
# Copy the working tree, minus git metadata and any previous build output.
( cd "$SRC" && tar --exclude=.git --exclude='*.o' --exclude='*.ko' --exclude='*.mod*' \
                   --exclude='.*.cmd' --exclude=packaging -cf - . ) | tar -xf - -C "$DEST"

sed "s/@VERSION@/$VERSION/g" "$TEMPLATE" > "$DEST/dkms.conf"

echo "staged. next:"
echo "  sudo dkms add   morse/$VERSION"
echo "  sudo dkms build morse/$VERSION"
