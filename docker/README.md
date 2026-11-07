# Docker build environment

Firmware for **Adventure Board** (RP2350A, no wireless) is built inside a
container so the toolchain does not have to be installed on the host.

## Prerequisites

- Docker Desktop with the WSL2 backend, with integration enabled for the
  Ubuntu distro.
- **The working copy must live on the WSL2 ext4 filesystem** (e.g.
  `~/dev/picorubykaigi01-board-firmware`), not under `/mnt/c`. picoruby tracks
  symlinks -- `mrblib`, `mrbgems/picoruby-mbedtls/lib/mbedtls`,
  `mrbgems/picoruby-socket/lib/lwip` and others -- and a Windows checkout
  materialises them as plain text files containing the target path, which
  breaks the build. Editing from Windows still works through VS Code's
  Remote-WSL extension, or via `\\wsl.localhost\Ubuntu\home\<user>\dev\...`.

Everything below has a `rake` front-end (`tasks/docker.rake`); the equivalent
plain `docker compose` command is given alongside it. Running `rake` on the
host only loads the build system in order to define the tasks -- it does not
need the firmware toolchain. Because `build/host` was built inside the
container, it prints one `output here was built by another configuration`
warning, which is harmless for these tasks.

## Build the image

```console
rake docker:image
# docker compose -f docker/compose.yml build
```

The image installs the prerequisites listed in
`mrbgems/picoruby-r2p2/README.md` (Ruby 3.4, cmake, `arm-none-eabi-gcc`,
`arm-linux-gnueabihf-gcc`, `qemu-arm-static`) plus **picotool**, which pico-sdk
2.x needs in order to emit `.uf2` images.

## Build the firmware

The `docker:r2p2:...` tasks mirror the native `r2p2:...` ones, one per
`build_config/r2p2-*.rb`. See `rake -T docker` for the full list.

```console
rake docker:r2p2:picoruby:pico2:prod     # this board
rake docker:r2p2:picoruby:pico2_w:prod   # Raspberry Pi Pico 2 W
rake docker:r2p2:picoruby:pico2_w:debug  # also produces the .elf for Picoprobe/gdb
rake docker:r2p2:femtoruby:pico2:prod    # mruby/c VM instead of the mruby VM
```

Artifacts land in `dist/{VM}-{BOARD}-{MODE}/` on the host (git-ignored). The
image is built automatically when it does not exist yet; rebuild it explicitly
with `rake docker:image` after editing the `Dockerfile`.

The same without rake -- `docker/build.sh` takes the target from the
environment, and `docker/compose.yml` defaults it to `picoruby`/`pico2`/`prod`:

```console
docker compose -f docker/compose.yml run --rm -e BOARD=pico2_w -e MODE=debug build
```

`VM` is `picoruby` or `femtoruby`, `BOARD` is `pico`/`pico_w`/`pico2`/`pico2_w`,
`MODE` is `prod` or `debug`; the same triple names the `docker:flash:...` task
below.

`PICORUBY_PSG_MCP4922_DMA`, `PICORUBY_PSG_PWM_DMA`, `R2P2_NO_SHARED_ALLOC`,
`R2P2_CONSOLE_UART` and `R2P2_USB_MIDI` are forwarded into the container when
they are set on the host, so they act the same way as in a native build.

`R2P2_USB_MIDI=1` builds the USB MIDI firmware (pico2 only): the board is also
a USB MIDI device, played on its speaker. It has build directories of its own
and lands in `dist/{vm}-{board}-{mode}-midi/`; flash it with the same variable
set (`R2P2_USB_MIDI=1 rake docker:flash:picoruby:pico2:prod`). See
[dev-docs/usb-midi/](../dev-docs/usb-midi/README.md).

`R2P2_CONSOLE_UART=1` puts the R2P2 shell on the board's default UART (UART0,
GPIO0/1, 115200) as well as on USB CDC -- for a board whose USB does not work,
such as the r1 prototype. That build owns UART0, so `UART.new(unit:
:RP2040_UART0)` is not available in it.

Throw away the build directories of one target with:

```console
rake docker:r2p2:picoruby:pico2_w:clean
```

## Interactive shell

```console
rake docker:shell
# docker compose -f docker/compose.yml run --rm shell
```

From there the ordinary upstream commands work, e.g. `rake r2p2:picoruby:pico2:prod`
or `rake` for the host build.

## Flashing over SWD (PicoProbe / Debug Probe)

The image carries an openocd built from `raspberrypi/openocd` (branch
`sdk-2.0.0`); Debian's 0.12.0 predates RP2350 and has no `target/rp2350.cfg`.
Nothing has to be installed on the host beyond attaching the probe to WSL.

```console
rake docker:flash:picoruby:pico2_w:prod
# docker compose -f docker/compose.yml run --rm -e BOARD=pico2_w flash
```

openocd programs the `.elf`, not the `.uf2`, so this uses the ELF of the same
target -- whichever of `dist/{VM}-{BOARD}-{MODE}/` and
`build/r2p2/{VM}/{BOARD}/{MODE}/` holds the newer one. Point it at a specific
file with `ELF=/work/...` , and lower the SWD clock with `ADAPTER_SPEED=1000`
if the wiring is long; both are forwarded into the container.

### Attaching the probe to WSL

WSL2 has no USB of its own, so the probe has to be forwarded from Windows with
[usbipd-win](https://github.com/dorssel/usbipd-win) once per plug-in. In an
**administrator** PowerShell:

```powershell
usbipd list                      # find the Debug Probe's BUSID
usbipd bind   --busid <BUSID>    # first time only, persists
usbipd attach --wsl --busid <BUSID>
```

`lsusb` in WSL should then show `2e8a:000c` (Raspberry Pi Debug Probe) or
`2e8a:0004` (a Pico running picoprobe firmware). Both speak CMSIS-DAP and are
matched by `interface/cmsis-dap.cfg`.

Docker Desktop runs the daemon in its own `docker-desktop` distro, but all
WSL2 distros share one kernel and one devtmpfs, so the attached probe shows up
in the container's `/dev/bus/usb` as well. The `flash` service in
`compose.yml` bind-mounts that directory rather than naming a `devices:` entry
because the bus/device number changes every time the probe is re-attached, and
it adds `device_cgroup_rules: ["c 189:* rmw"]` -- without that rule the node is
visible but the device cgroup denies the open.

### Flashing by drag-and-drop instead

Without a probe: hold BOOTSEL while plugging the board in, then copy the
`.uf2` from `dist/` onto the `RPI-RP2` drive from Windows.

## Notes

- Compiler output stays in the working tree (`build/`, `bin/`), both
  git-ignored upstream; `docker/build.sh` additionally copies the finished
  artifacts to `dist/`. Only the bundled gems live in a Docker volume --
  `rake docker:clean` drops it together with the image.
- The container runs as the invoking user's uid/gid (`HOST_UID`/`HOST_GID` in
  `compose.yml`, defaulting to `1000:1000`), so what it writes into the working
  tree stays editable from the host. An older build that ran as root leaves
  files the host `rake` cannot use: loading the build system rewrites
  `src/version.c`, which fails on a root-owned one.
- `BOARD=pico2` uses the stock Raspberry Pi Pico 2 board definition from
  pico-sdk. Adventure Board is a custom RP2350A design (W25Q32/W25Q64
  flash, 12 MHz crystal), so a dedicated board header under
  `mrbgems/picoruby-r2p2/lib/pico-sdk/src/boards/include/boards/` — or a
  `PICO_BOARD_HEADER_DIRS` entry pointing at one kept in this repository — is
  still to be added.
