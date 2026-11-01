MRuby::CrossBuild.new("r2p2-picoruby-pico2#{ENV['R2P2_USB_MIDI'] ? '-midi' : ''}#{ENV['PICORB_DEBUG'] ? '-debug' : ''}") do |conf|

  ###############################################################
  # You need following tools:
  #   arm-none-eabi       | to make libmruby.a
  ###############################################################

  conf.toolchain("gcc")

  conf.cc.defines << "PICORB_PLATFORM_RP2"

  conf.cc.defines << "MRB_TICK_UNIT=1"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=10"

  conf.cc.defines << "MRB_UTF8_STRING"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_32BIT"
  conf.cc.defines << "MRB_USE_CUSTOM_RO_DATA_P"
  conf.cc.defines << "MRB_LINK_TIME_RO_DATA_P"
  conf.cc.defines << "NO_CLOCK_GETTIME=1"

  conf.cc.command = "arm-none-eabi-gcc"
  conf.linker.command = "arm-none-eabi-ld"
  conf.linker.flags << "-static"
  conf.archiver.command = "arm-none-eabi-ar"

  conf.cc.host_command = "gcc"

  conf.cc.flags.flatten!
  conf.cc.flags << "-mcpu=cortex-m33"
  conf.cc.flags << "-mthumb"

  conf.cc.flags << "-fno-strict-aliasing"
  conf.cc.flags << "-fno-unroll-loops"
  conf.cc.flags << "-mslow-flash-data"

  conf.cc.flags << "-fshort-enums"

  conf.cc.flags << "-Wall"
  conf.cc.flags << "-Wno-format"
  conf.cc.flags << "-Wno-unused-function"
  conf.cc.flags << "-ffunction-sections"
  conf.cc.flags << "-fdata-sections"

  conf.picoruby

  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gembox "shell"
  conf.gembox "peripherals"
  conf.gembox "peripheral_utils"
  conf.gem core: 'picoruby-is31fl3729'
  conf.gem core: 'picoruby-pio-uart'
  conf.gem core: 'picoruby-adc-capture'
  conf.gem core: 'picoruby-psg'
  conf.gem core: 'picoruby-midibase-mml'
  conf.gem core: 'picoruby-midibase-looper'
  conf.gem core: 'picoruby-uart-midi'
  conf.gem core: 'picoruby-usb-cdc-midi'
  conf.gem core: 'picoruby-shinonome'
  conf.gem core: 'picoruby-ssd1306'     # I2C OLED (SSD1306 / SSD1315) on the breadboard or GROVE

  # The USB MIDI build (R2P2_USB_MIDI=1): the board is also a class-compliant
  # USB MIDI device. tasks/picoruby/r2p2.rake puts it in build directories of
  # its own and turns the MIDI interface on in the USB descriptors.
  #
  # USB_MIDI_DEVICE is a picoruby-midibase transport here (getevent /
  # putevent, like UART::MIDI), so it plays PSG::Synth with no MIDI layer of
  # its own. UsbMidi (lib/adventure_board/usb_midi.rb) is built in rather than
  # compiled from /lib on the board, for the heap (dev-docs/usb-midi/).
  if ENV['R2P2_USB_MIDI']
    conf.gem core: 'picoruby-usb_midi_device' do |spec|
      spec.add_dependency 'picoruby-midibase'
      spec.rbfiles << "#{spec.dir}/mrblib_midibase/usb_midi_device_midibase.rb"
    end
    conf.gem core: 'picoruby-adventure_board-usb_midi'
  end
end
