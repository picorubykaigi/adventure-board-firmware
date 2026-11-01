# USB MIDI の楽器。PC から送った MIDI を基板のスピーカーで鳴らす。
#
# USB MIDI 版のファームウェア（adventure-board-*-midi.uf2）でだけ動く。
# 基板は PC から「PicoRuby MIDI」という MIDI 機器に見えるので、DAW や
# Web MIDI に対応したページで、MIDI の出力先にそれを選ぶ。
#
# 同時に鳴る音は 3 つまで（PSG は 3 声）。チャンネル 10 はドラム。
# 鳴った音が LED に光る（横が音の高さ、縦が強さ）。B ボタンで終わる。
#
# 反対向きに、基板から PC へも送れる。上・下・左・右のボタンを押すと、
# チャンネル 1 で ド・レ・ミ・ファ（C・D・E・F）のノートオンを、離すとノートオフを送る。
# PC の DAW などで、MIDI の入力に「PicoRuby MIDI」を選ぶと聞こえる。

require 'adventure_board'
GC.start

matrix = AdventureBoard.matrix
buttons = AdventureBoard.buttons
midi = AdventureBoard.usb_midi

# 列ごとの光の高さ（0〜16）。音が来たら伸びて、だんだん縮む
bars = Array.new(16, 0)

# PC へ送る音。ボタンと MIDI の音の高さ（60 が C4 のド）
KEYS = { up: 60, down: 62, left: 64, right: 65 }
CHANNEL = 0          # チャンネル 1（MIDI のチャンネルは 0 から数える）
usb = midi.usb       # PC との USB MIDI
held = {}            # いま押しているボタン

# 届いた MIDI を 1 つずつ受け取る。e は [:note_on, チャンネル, 音の高さ, 強さ] のような配列
midi.on_message do |e|
  if e[0] == :note_on
    bars[e[2] % 16] = e[3] / 8 + 1
  end
end
midi.start

puts "PC の MIDI の出力先に「PicoRuby MIDI」を選んでください。B ボタンで終わります"
puts "（PC にまだつながっていません）" unless midi.connected?

until buttons.pressed?(:b)
  # 押したとき・離したときだけ送る（押しているあいだ送り続けない）
  KEYS.each do |name, note|
    down = buttons.pressed?(name)
    if down && !held[name]
      usb.putevent(:note_on, CHANNEL, note, 100)
      held[name] = true
    elsif !down && held[name]
      usb.putevent(:note_off, CHANNEL, note, 0)
      held[name] = false
    end
  end

  matrix.clear_drawing
  x = 0
  while x < 16
    h = bars[x]
    if h > 0
      matrix.draw_line(x, 16 - h, x, 15, 0x80)
      bars[x] = h - 1
    end
    x += 1
  end
  matrix.blit                     # 描いたものを LED ドライバへコピー
  matrix.show                     # LED ドライバへ送る（これで光る）

  # 届いた MIDI は、待っているあいだに別のタスク（UsbMidi）が鳴らす
  sleep_ms 40
end

# 押したまま終えたボタンの音を止める
KEYS.each do |name, note|
  usb.putevent(:note_off, CHANNEL, note, 0) if held[name]
end
midi.stop
matrix.clear
matrix.show
puts "おわり"
