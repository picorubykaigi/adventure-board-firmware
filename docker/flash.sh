#!/usr/bin/env bash
# Flashes an already-built R2P2 image onto the board over SWD, through a
# CMSIS-DAP probe (Raspberry Pi Debug Probe, or a Pico running picoprobe
# firmware), using the openocd built into the image.
#
# openocd programs an ELF, not the .uf2 that BOOTSEL drag-and-drop takes, so
# this picks the .elf of the requested target.
#
# Override the target with environment variables, e.g.
#   docker compose -f docker/compose.yml run --rm -e BOARD=pico2_w flash
set -euo pipefail

VM="${VM:-picoruby}"
BOARD="${BOARD:-pico2}"
MODE="${MODE:-prod}"
VARIANT="${R2P2_USB_MIDI+-midi}"   # the USB MIDI build, as docker/build.sh names it
ADAPTER_SPEED="${ADAPTER_SPEED:-5000}"

# Rebooting is done through the watchdog rather than openocd's `reset`, which
# is SYSRESETREQ: it restarts the core and leaves every peripheral running,
# USB included, and R2P2 starting up against a half-live USB device hangs
# before it reaches a prompt -- badly enough that SWD stops answering and only
# BOOTSEL recovers it. These are the writes watchdog_reboot() makes on the
# device: point the power-on state machine at everything but the oscillators,
# clear the scratch register that would redirect the boot, pull the trigger.
case "$BOARD" in
  pico|pico_w)
    target_cfg=target/rp2040.cfg
    psm_wdsel=0x40010008;  wdsel_value=0x0001fffc
    wd_scratch4=0x4005801c; wd_ctrl=0x40058000
    ;;
  pico2|pico2_w)
    target_cfg=target/rp2350.cfg
    psm_wdsel=0x40018008;  wdsel_value=0x01fffff3
    wd_scratch4=0x400d801c; wd_ctrl=0x400d8000
    ;;
  *) echo "Unknown BOARD: $BOARD" >&2; exit 1 ;;
esac

elf="${ELF:-}"
if [ -z "$elf" ]; then
  # dist/ is what docker/build.sh publishes; build/ is where cmake wrote it and
  # is the only one populated by a bare `rake r2p2:...`. Newest of the two wins.
  shopt -s nullglob
  candidates=(
    "/work/dist/${VM}-${BOARD}-${MODE}${VARIANT}"/R2P2*.elf
    "/work/build/r2p2/${VM}/${BOARD}${VARIANT}/${MODE}"/R2P2*.elf
  )
  if [ ${#candidates[@]} -eq 0 ]; then
    echo "No R2P2 .elf for ${VM}/${BOARD}/${MODE}." >&2
    echo "Build it first: rake docker:r2p2:${VM}:${BOARD}:${MODE}" >&2
    exit 1
  fi
  # shellcheck disable=SC2012  # the names are ours and contain no newlines
  elf=$(ls -t "${candidates[@]}" | head -1)
fi

if [ ! -r "$elf" ]; then
  echo "Cannot read ELF: $elf" >&2
  exit 1
fi

echo "Flashing $elf (${BOARD}, ${target_cfg})"

openocd \
  -f interface/cmsis-dap.cfg \
  -f "$target_cfg" \
  -c "adapter speed ${ADAPTER_SPEED}" \
  -c "program \"${elf}\" verify exit"

# A separate session: after a flash operation the target is somewhere these
# writes cannot reach. The halt is best effort: the watchdog registers take
# the writes from a running core too, and on the r1 board openocd cannot
# halt at all (dev-docs/device-bringup/r1-board.md). The trigger write is
# wrapped as well: the reset it causes cuts the transaction short and
# openocd reports "Failed to write memory", and without the catch that
# counts as a failed attempt and the retry reboots the board again -- in the
# middle of the /lib install the first reboot just started. The probe can take a moment to come back between the
# two, especially over usbip, so give it a few tries -- and if it never does,
# say so rather than failing a flash that already verified.
echo "Rebooting through the watchdog"
for attempt in 1 2 3; do
  if openocd \
      -f interface/cmsis-dap.cfg \
      -f "$target_cfg" \
      -c "adapter speed ${ADAPTER_SPEED}" \
      -c "init; catch {halt}; mww ${psm_wdsel} ${wdsel_value}; mww ${wd_scratch4} 0; catch {mww ${wd_ctrl} 0x80000000}; exit"; then
    exit 0
  fi
  sleep 1
done

echo "Flashed and verified, but could not reboot the board." >&2
echo "Power-cycle it, or run: tools/r2p2dev.py reset" >&2
exit 0
