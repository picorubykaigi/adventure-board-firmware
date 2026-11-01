# Board support for Adventure Board.
#
# This file is not a gem. It is meant to live on the device's filesystem as
# /lib/adventure_board.rb and be picked up by `require 'adventure_board'`, so
# that anyone can open it, read the pin numbers and change them. The register
# level work is in the picoruby-is31fl3729 gem; what is here is the part worth
# reading.
#
# Pin assignments come from
# ref/picorubykaigi01-board/docs/PicoBoard_BOM_pin_assignment_20260824.xlsx,
# which is machine-extracted from the board. docs/gpio_assignment.md is older
# and disagrees; do not use it.
#
# This file brings in Board, which is the pins and how to bring them up, and
# AdventureBoard, which is what a program asks for its peripherals. The
# peripherals live one class per file beside it, and each is read the first
# time a program asks for it, so a program is:
#
#   require 'adventure_board'
#   GC.start
#   matrix = AdventureBoard.matrix      # reads adventure_board/led_matrix
#
# Reading only what is asked for is not ceremony. Compiling Ruby on the device
# costs about six times the source size in contiguous heap and leaves about
# five times it resident, so loading the LED matrix in order to blink the
# status LED is a real price a program pays. Measurements in
# dev-docs/device-bringup/require-memory.md.
#
# And it is read here, not by a require inside the peripheral's file: a
# require nested in another file compiles while the outer file is still held,
# and on the r1 board that left the largest free block at 7-20KB instead of
# about 25KB -- kanji.rb right after a reset, or melody.rb after it, ran out of
# memory one time in two or three.

require 'adventure_board/board'

# --- what a program calls ----------------------------------------------------
#
# A program takes each peripheral it uses into a variable of its own, so that
# reading the program says where `matrix` came from. (These used to be
# top-level methods, `matrix` and friends, which looked like variables with
# no assignment anywhere, and a program's own `board = []` quietly hid one.)
#
# `$board` is set by whoever brought the board up: nothing on the device, where
# the first call boots it; the page in the simulator, which hands in stand-ins.
# A program never has to know how the peripherals were built, and the same
# source runs in both places.
module AdventureBoard
  # The date of this library. Raised whenever anything under lib/ changes:
  # the console shows it when it writes the library to a board. The library
  # the first firmware (v2026.10.25) wrote has no VERSION.
  VERSION = "2026.11.01"

  # The Board itself, for what is not below: its pins, and how it was built.
  def self.board
    $board ||= Board.boot
  end

  def self.matrix
    use(:LedMatrix, 'adventure_board/led_matrix')
    board.matrix
  end

  def self.buttons
    use(:Buttons, 'adventure_board/buttons')
    board.buttons
  end

  def self.speaker
    use(:Speaker, 'adventure_board/speaker')
    board.speaker
  end

  def self.status_led
    use(:StatusLed, 'adventure_board/status_led')
    board.status_led
  end

  # GROVE-B (J5) as a plain UART, or as the board-to-board link.
  def self.grove_uart(baudrate: 115200)
    board.grove_uart(baudrate: baudrate)
  end

  def self.grove_link(role: :a, baudrate: nil)
    use(:GroveLink, 'adventure_board/grove_link')
    baudrate ? board.grove_link(role: role, baudrate: baudrate) : board.grove_link(role: role)
  end

  # The board as a USB MIDI instrument, played on the speaker. Only the USB
  # MIDI firmware has it (the ordinary one has no MIDI interface on its USB).
  def self.usb_midi
    unless Object.const_defined?(:USB_MIDI_DEVICE) && USB_MIDI_DEVICE.method_defined?(:getevent)
      raise "USB MIDI needs the USB MIDI firmware (adventure-board-*-midi.uf2)"
    end
    use(:UsbMidi, 'adventure_board/usb_midi')
    @usb_midi ||= UsbMidi.new(speaker: speaker)
  end

  # GROVE-A (J4), the I2C one.
  def self.grove_i2c(frequency: 100_000)
    board.grove_i2c(frequency: frequency)
  end

  # Reads a peripheral's file the first time it is needed, and gives back
  # what compiling it took. Already there (the simulator has every class from
  # the start), nothing is read.
  def self.use(name, path)
    return if Object.const_defined?(name)
    require path
    GC.start
  end
end
