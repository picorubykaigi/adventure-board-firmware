# The board as a USB MIDI instrument: what a PC sends to the board's MIDI
# port is played on the speaker.
#
# Only with the USB MIDI firmware (the build made with R2P2_USB_MIDI=1). The
# board then shows up on the PC as a MIDI device, "PicoRuby MIDI", beside the
# serial ports it always has, so a DAW or a browser page can pick it as an
# output. The ordinary firmware has no MIDI interface, and
# AdventureBoard.usb_midi says so.
#
# The path, from the cable to the speaker:
#
#   PC --USB MIDI--> picoruby-usb_midi_device (a ring, filled by the USB pump)
#      --> USB_MIDI_DEVICE#getevent, a picoruby-midibase transport like
#          UART::MIDI, in a task of its own (the "UsbMidi" task below)
#      --> PSG::Synth#handle, the same sound generator Speaker plays MML on
#      --> PWM on GPIO10 --> RC filter --> PAM8302A --> speaker
#
# The events are picoruby-midibase's ([:note_on, channel, note, velocity],
# ...), the same as the MML that Speaker plays, so nothing is converted.
#
# The PSG has three voices: a fourth note at once takes the oldest one's
# voice. Channel 10 is the drums (PSG.drum_program).
#
# The USB MIDI firmware has this class built in (the gem
# picoruby-adventure_board-usb_midi compiles this very file), so the board
# does not compile it at run time: that took more heap than was left once a
# program had read the matrix, the buttons and the speaker. Editing the copy
# in /lib on the board therefore changes nothing; it is there to be read.
#
#   midi = AdventureBoard.usb_midi
#   midi.start
#   loop { sleep_ms 100 }     # the messages are played meanwhile
class UsbMidi
  # PSG::Synth keeps a channel's settings (volume, program, ...) per sender,
  # so what the PC sets does not leak into the MML that Speaker plays.
  SOURCE = :usb_midi

  # MIDI channel 16 (15 counting from 0) is the last: the PSG's channels are
  # whatever the PC sends on.
  CHANNELS = 16

  attr_reader :speaker, :usb

  # `pan` is where every channel sits. The board has one speaker, on the
  # PSG's left output, so the PC's pan (CC 10) would only make it quieter:
  # it is ignored, and each channel stays here.
  def initialize(speaker:, pan: Board::PSG_SPEAKER_PAN)
    @speaker = speaker
    @synth = speaker.sink
    @usb = USB_MIDI_DEVICE.instance
    @pan = pan
    @task = nil
    @on_message = nil
    @sounding = false
  end

  # Whether the PC has opened the board as a USB device. A DAW may still
  # not be sending to it.
  def connected?
    @usb.connected?
  end

  def started?
    !@task.nil?
  end

  # Start playing what arrives, in a task of its own: the program goes on,
  # and waits with plain sleep_ms.
  def start
    return self if @task
    channel = 0
    while channel < CHANNELS
      send_event([:control_change, channel, 10, @pan])
      channel += 1
    end
    me = self
    @task = Task.new(name: "UsbMidi") { me.run }
    self
  end

  # Stop listening, silence every channel and mute the amplifier.
  def stop
    task = @task
    # Closed, not only stopped: a task stays in the heap until it is
    # (dev-docs/device-bringup/task-memory.md)
    task.close if task
    @task = nil
    channel = 0
    while channel < CHANNELS
      send_event([:control_change, channel, 64, 0])    # sustain off
      send_event([:control_change, channel, 123, 0])   # all notes off
      channel += 1
    end
    @speaker.mute
    @sounding = false
    self
  end

  # Something else to do with each message as well, e.g. light the matrix:
  #
  #   midi.on_message { |e| matrix.set(e[2] % 16 + 1, 16, 255) if e[0] == :note_on }
  #
  # The block gets the event as an Array, [command, channel, ...]:
  # [:note_on, channel, note, velocity], [:control_change, channel, number,
  # value], ... (picoruby-midibase's). It runs in the "UsbMidi" task, after
  # the sound generator has the event.
  def on_message(&block)
    @on_message = block
    self
  end

  # Internal: the "UsbMidi" task. getevent waits (sleep_ms 1 at a time) until
  # a whole message has arrived.
  def run
    usb = @usb
    while true
      receive(usb.getevent)
    end
  end

  # Internal: one message from the PC
  def receive(event)
    if playable?(event)
      unless @sounding
        @speaker.unmute
        @sounding = true
      end
      send_event(event)
    end
    block = @on_message
    block.call(event) if block
  end

  private def send_event(event)
    @synth.handle(event, source: SOURCE)
  end

  # What PSG::Synth plays: the channel messages, except the PC's pan
  private def playable?(event)
    case event[0]
    when :note_on, :note_off, :program_change, :pitch_bend
      true
    when :control_change
      event[2] != 10
    else
      false
    end
  end
end
