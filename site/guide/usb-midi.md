# USB MIDI で鳴らす

**USB MIDI 版**のファームウェアを書き込むと、Adventure Board がパソコンから **USB MIDI の楽器**に見えます。
DAW（GarageBand、Ableton Live、Cubase など）や、Web MIDI に対応したブラウザのページから
MIDI を送ると、基板のスピーカーで鳴ります。

USB MIDI 版はふつうのファームウェアとは**別のファイル**です。ふつうの版には MIDI の機能が入っていません。

## 1. USB MIDI 版を書き込む

[リリースのページ](https://github.com/picorubykaigi/adventure-board-firmware/releases) から、
名前が `-midi.uf2` で終わるファイル（`adventure-board-2026.11.01-midi.uf2` のような名前）をダウンロードし、
[ファームウェアの書き込み](./firmware) と同じ手順で書き込みます。

ふつうの版に戻すときは、ふつうの `.uf2` を書き込み直します。どちらの版でも、ファイルやプログラムはそのまま残ります。

USB MIDI 版を書き込むと、パソコンからは**別の機器**に見えます（USB の中身が変わるため）。
コンソールで基板を選び直してください。シリアル（WebSerial）は、ふつうの版と同じように使えます。

## 2. 楽器にする

[R2P2のシェル](./shell) で、サンプルを実行します。

```text
$> /home/examples/usb_midi_synth.rb
```

パソコンの DAW などで、MIDI の出力先に **PicoRuby MIDI** を選んで鍵盤を弾くと、基板のスピーカーで鳴ります。
鳴った音が LED に光ります（横が音の高さ、縦が強さ）。**B ボタン**で終わります。

反対向きに、基板から PC へも送れます。**上・下・左・右のボタン**を押すと、チャンネル 1 で
ド・レ・ミ・ファ（C・D・E・F）を送ります。DAW などで、MIDI の入力に **PicoRuby MIDI** を選ぶと聞こえます。

- 同時に鳴る音は **3 つまで**です（基板の音源 PSG は 3 声）。4 つ目を弾くと、いちばん古い音が止まります
- **チャンネル 10** はドラムです（キック・スネア・ハイハットなど）
- 音量（CC 7）・プログラムチェンジ・ピッチベンド・サステイン（CC 64）が効きます。パン（CC 10）は無視します（スピーカーが 1 つなので）

## 3. 自分のプログラムで使う

```ruby
require 'adventure_board'
GC.start

midi = AdventureBoard.usb_midi
midi.start                      # パソコンから届いた MIDI を鳴らし始める

loop do
  sleep_ms 100                  # 待っているあいだも、届いた MIDI は鳴る
end
```

`midi.start` のあとは、届いた MIDI を別のタスクが鳴らします。プログラムは止まらずに先へ進み、ふつうの `sleep_ms` で待てます。
`midi.stop` で止まります。

届いた MIDI を見て、ほかのこともできます。

```ruby
midi.on_message do |e|
  puts "音 #{e[2]} 強さ #{e[3]}" if e[0] == :note_on
end
```

PC へ送るには `midi.usb.putevent` を使います。

```ruby
midi.usb.putevent(:note_on, 0, 60, 100)   # チャンネル 1 で C4（ド）を強さ 100 で
midi.usb.putevent(:note_off, 0, 60, 0)
```

`e` は `[:note_on, チャンネル, 音の高さ, 強さ]` のような配列です。最初が種類
（`:note_on`・`:note_off`・`:control_change`・`:program_change`・`:pitch_bend` など）、
次がチャンネル（0〜15。チャンネル 1 が 0）です。MML の `Speaker` が使っているのと同じ形です。

ふつうの版で `AdventureBoard.usb_midi` を呼ぶと、USB MIDI 版が要るというエラーになります。
シミュレータでも動きません。
