# UsbMidi (lib/adventure_board/usb_midi.rb) built into the USB MIDI firmware
# (R2P2_USB_MIDI), so that AdventureBoard.usb_midi finds the class there and
# does not require the file. Compiling a file on the board takes about six
# times its source in contiguous heap and leaves some 20KB behind, and with
# the board library, the matrix, the buttons and the speaker read first,
# that was the request that ran out of memory (dev-docs/usb-midi/).
#
# The source stays lib/adventure_board/usb_midi.rb, to be read like the rest
# of the library; /lib on the board carries it too, for reading.
MRuby::Gem::Specification.new('picoruby-adventure_board-usb_midi') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Toshio Maki'
  spec.summary = 'UsbMidi of the Adventure Board library, built in'

  spec.add_dependency 'picoruby-usb_midi_device'
  spec.rbfiles = [File.expand_path('../../lib/adventure_board/usb_midi.rb', __dir__)]
end
