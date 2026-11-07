#!/usr/bin/env bash
# Builds the R2P2 firmware inside the container and copies the artifacts to
# /work/dist, which is on the bind mount and therefore visible from the host.
#
# Override the target with environment variables, e.g.
#   docker compose -f docker/compose.yml run --rm -e MODE=debug build
set -euo pipefail

VM="${VM:-picoruby}"
BOARD="${BOARD:-pico2}"
MODE="${MODE:-prod}"
# The USB MIDI build (R2P2_USB_MIDI set) has build directories of its own;
# tasks/picoruby/r2p2.rake names them with the same suffix.
VARIANT="${R2P2_USB_MIDI+-midi}"

cd /work

bundle check >/dev/null 2>&1 || bundle install

# The cmake build compiles the Ruby sources with ${PICORUBY_ROOT}/bin/mrbc, but
# `rake r2p2:...` only builds the cross target and its own internal mrbc under
# build/mrbc/. bin/mrbc comes from the host build, so run that first. It is
# incremental, and rake's build_host helper cleans build/host by itself when the
# VM variant changes.
rake "${VM}:${MODE}"

rake "r2p2:${VM}:${BOARD}:${MODE}"

out="/work/build/r2p2/${VM}/${BOARD}${VARIANT}/${MODE}"
dist="/work/dist/${VM}-${BOARD}-${MODE}${VARIANT}"
mkdir -p "$dist"

# The image name carries the commit, so the build directory accumulates one set
# per commit built. Publish only the newest, and clear dist first: copying them
# all gives every file the same timestamp, and then "the latest image" is
# whatever the shell happens to list first -- which is how you flash last
# week's firmware and spend an hour wondering why your fix did nothing.
shopt -s nullglob
newest_elf=$(ls -t "$out"/R2P2*.elf 2>/dev/null | head -1)
if [ -z "$newest_elf" ]; then
  echo "No R2P2 artifacts found in $out" >&2
  exit 1
fi
stem=$(basename "$newest_elf" .elf)
rm -f "$dist"/R2P2*.uf2 "$dist"/R2P2*.elf
cp -v "$out/$stem".uf2 "$out/$stem".elf "$dist/"

echo
echo "Artifacts copied to dist/${VM}-${BOARD}-${MODE}${VARIANT}/ :"
ls -l "$dist"
