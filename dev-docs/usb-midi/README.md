# USB MIDI 版のファームウェア（2026-11-01）

基板を **PC から USB MIDI 楽器として鳴らす**ための別ビルド。利用者向けの説明は
[site/guide/usb-midi.md](../../site/guide/usb-midi.md)、upstream のファイルに入れた変更は
[upstream-changes.md](../upstream-changes.md) の 15。

## 使っているもの

- [mrbgems/picoruby-usb_midi_device](../../mrbgems/picoruby-usb_midi_device)（kirikak2/picoruby-usb_midi_device、MIDoRI と共有）……
  USB MIDI デバイスのトランスポート。今回 `ports/rp2040/usb_midi_device.c`（R2P2 の port）と
  `mrblib_midibase/usb_midi_device_midibase.rb`（picoruby-midibase のトランスポートにする。build_config で足す）を足した
- upstream の **picoruby-midibase**（`Speaker` の MML と同じ MIDI の層）。`USB_MIDI_DEVICE` を `UART::MIDI` と同じ形の
  トランスポートにして、`getevent` で受けたイベントをそのまま `PSG::Synth` に渡す
- [lib/adventure_board/usb_midi.rb](../../lib/adventure_board/usb_midi.rb)（`UsbMidi`、`AdventureBoard.usb_midi`）…… 受けた MIDI を `PSG::Synth` に渡す
- [mrbgems/picoruby-adventure_board-usb_midi](../../mrbgems/picoruby-adventure_board-usb_midi) …… `UsbMidi` を MIDI 版のファームに焼き込む（後述「メモリ」）
- [examples/usb_midi/usb_midi_synth.rb](../../examples/usb_midi/usb_midi_synth.rb) …… MIDI ビルドのファームにだけ入るサンプル

`usb-cdc-midi`（CDC2 に生の MIDI バイトを流す、WebSerial 用）は両方のビルドにある。

### picoruby-midi をやめた理由（2026-11-01）

最初は MIDoRI の picoruby-midi（C のルート表・filter・`MIDI.on`・スケジューラ・`MIDI::Clock`）を使い、`ports/rp2040/midi.c` を書いた。
動いたが、MIDIBASE が既に両方のビルドにある（`Speaker`）ので、MIDI の層が 2 つ並んでいた。picoruby-midi をやめて MIDIBASE に乗せると:

- RP2 の port が要らない（picoruby-midi の port は約 500 行で、SDK のアラームプールのタイマー 3 本・IRQ と VM のあいだのキュー・
  SysEx を IRQ でパースしない工夫などを持っていた）
- picoruby-midi の `MIDI_Filter_wait()` は C で待つので、R2P2 ではそのままだと mruby のタスクが全部止まる（`PSG::Synth` も止まる）。
  そのため「見るだけで返して Ruby が寝る」形に gem を変える必要があった。MIDIBASE の `getevent` は最初から `sleep_ms 1` で待つ
- 使う側は素の `sleep_ms` で待てる（`MIDI.sleep_ms` を使い分けなくてよい）
- 失うのは C だけで転送するルート（MIDI Thru）・ノートスケジューラ・`MIDI::Clock`。楽器の用途では使っていなかった

## ビルド

```console
R2P2_USB_MIDI=1 R2P2_CONSOLE_UART=1 rake docker:r2p2:picoruby:pico2:prod   # → dist/picoruby-pico2-prod-midi/
R2P2_USB_MIDI=1 rake docker:flash:picoruby:pico2:prod                       # SWD で書くときも同じ変数を付ける
```

`R2P2_USB_MIDI` は「値に関係なく、設定されていれば有効」（`R2P2_CONSOLE_UART` と同じ）。
**ビルド名・ディレクトリに `-midi` が付く**（libmruby は `build/r2p2-picoruby-pico2-midi[-debug]/`、cmake は
`build/r2p2/picoruby/pico2-midi/{debug,prod}/`）。gem の構成が違う libmruby を通常版と同じ場所に作ると、
rake が既にある `libmruby.a` を使い回して混ざるため。gem の構成を変えたら `build/r2p2-picoruby-pico2-midi` を消してから作る。

## USB の構成

R2P2 の複合デバイス（CDC×3 + HID×3）に、IAD 付きの MIDI 機能（Audio Control + MIDI Streaming、
インターフェース 9・10、EP 0x0A / 0x8A、64 byte）を足す。インターフェース名は "PicoRuby MIDI"（文字列 10）。

picoruby-usb_midi_device は ESP32 と同じく自分のディスクリプタ（`ports/rp2040/usb_descriptors.c`、MIDI だけ、または CDC 付き）も
持っているが、R2P2 は自分のディスクリプタに MIDI を足すので、CMake で `USB_MIDI_DEVICE_OWN_DESCRIPTORS=0` を渡して gem のほうを
ビルドしない（両方あると `tud_descriptor_*_cb()` が二重になってリンクできない）。

- **PID を 0x400F → 0x401F に変えている。** `usb_descriptors.c` の `_PID_MAP` はクラスの数をビット位置にずらして OR するので、
  HID が 3 個（`3 << 2` = 0x0C）の時点で MIDI のビット（0x08）も立っていて、MIDI を足しても 0x400F のまま変わらない。
  ホストは VID/PID ごとにインターフェースの構成を覚えるので、同じ PID のまま中身を変えると混乱しうる。
  PC からは別の機器に見え、WebSerial のポートも選び直しになる
- IAD を付けたのは、他の機能（CDC）がそうなっている複合デバイスの中で、Windows が MIDI の 2 つのインターフェースを
  1 つの機能として扱うように。TinyUSB の `usbd.c` は IAD があってもなくても MIDI を 2 インターフェースとして開く

## スレッドと割り込み

R2P2 には RTOS が無い（TinyUSB は `OPT_OS_NONE`、ロック無し）。TinyUSB を呼んでよいのは picoruby-machine の
**USB pump**（`usb_pump_worker()` = 最低優先度の IRQ、と `Machine_tud_task()`、どちらも `usb_mutex` を持って `tud_task()` を呼ぶ）だけ。
そこで USB MIDI の TinyUSB 呼び出しは全部 `tud_task()` の中で行う。`tud_midi_rx_cb()` と、VM が TinyUSB の
**`usbd_defer_func()`** で `tud_task()` のキューに積んだ関数の中。picoruby-machine には手を入れていない
（最初は pump にフックを足したが、`usbd_defer_func()` で代わりが利くので取り下げた）。

```
受信: PC → TinyUSB の MIDI FIFO → [tud_task: tud_midi_rx_cb] tud_midi_packet_read → RX リング
      → [Ruby タスク UsbMidi] USB_MIDI_DEVICE#getevent（_read_byte でパケットをバイトに戻し、MIDIBASE::Parser）
      → UsbMidi#receive → PSG::Synth#handle（キュー）→ [Ruby タスク PSG::Synth] → core1 の PSG
送信: VM → putevent（MIDIBASE.encode → _write_message でパケットに詰める）→ TX リング、usbd_defer_func
      → [tud_task: 積んだ関数] tud_midi_packet_write → PC
```

- `usbd_defer_func()` はキューに USB 割り込みを止めて積むので、スレッド（VM）から呼んでよい。`tud_task()` の中から積み直すと、
  `tud_task()` がキューを空にするまで回り続けるので、積むのは VM からだけ。この port は IRQ から呼ばない
- TinyUSB のイベントキューは 16 件で USB 割り込みと共用。満杯だと積んだ呼び出しが黙って捨てられるので、積むのは一度に 1 つにし、
  5 ms 経っても実行されなければ積み直す
- リングの push / pop は割り込みを止めて行う。RX リングが満杯なら TinyUSB の FIFO から読まず、ホストには NAK が返る
  （取りこぼさず待たせる）。VM がリングから読んで空きができたら、残りを取りに行く呼び出しを積む
- TinyUSB の TX FIFO（64 byte）に入りきらなかった分は TX リングに残り、次の送信で吐く
- pump は picoruby-machine の 1 ms tick が必ず起こすので、積んだ呼び出しの遅れは最大 1 ms
- `getevent` は何も来ていないあいだ `sleep_ms 1` で待つ（`UART::MIDI` と同じ）。UsbMidi のタスクは 1 ms ごとに起きる
- `getevent` と `read_available` は同じ RX リングから取る。どちらか一方だけを使う

## 発音（`UsbMidi`）

- イベントは MIDIBASE のもの（`[:note_on, ch, note, vel]` など）。`Speaker` の MML と同じ形なので変換しない
- `PSG::Synth#handle(event, source: :usb_midi)`。`Synth` はチャンネルの設定（音量・音色など）を**送り主 × チャンネル**で
  覚えるので、PC から来た設定が `Speaker` の MML（送り主 `:mml`）に漏れない
- パン（CC 10）は無視して、全チャンネルを `Board::PSG_SPEAKER_PAN`（左いっぱい）に置く。スピーカーは PSG の左出力だけ
- チャンネル 10 のドラムは `PSG::Synth` が自分で扱う（`PSG.drum_program`）
- アンプ（SD ピン）は最初の音で入れ、`stop` で切る。`stop` は受信タスクを `close` する（止めるだけだとヒープに残る。
  [device-bringup/task-memory.md](../device-bringup/task-memory.md)）

## メモリ（2026-11-01、V1 の実機、prod）

picoruby-midi を使っていた版の記録。最初の版は `usb_midi_synth.rb` が `NoMemoryError` で落ちた。`free` の結果:

| | used | free | max_free | T_PROC |
|---|---|---|---|---|
| 通常版 起動直後 | 217,456 | 187,672 | 178,816 | 1426 |
| MIDI 版 起動直後 | 241,512 | 163,616 | 155,192 | 1727 |
| MIDI 版 `usb_midi_synth.rb` が落ちた後 | 381,392 | 23,736 | **5,968**（frag 67） | 1803 |
| MIDI 版（下の対策後）起動直後 | **214,160** | 190,968 | **182,560**（frag 7） | 1302 |

- gem の常駐分（起動直後の差）は **24KB**。mruby は起動時に全 gem の mrblib を読む。picoruby-midi はメソッドが約 240 個
- サンプルが食ったのは **140KB**。`require` が 6 本（`adventure_board` / `board` / `led_matrix` / `buttons` / `speaker` / `usb_midi`）で、
  均すと 1 本あたり約 23KB（`require` の費用は [device-bringup/require-memory.md](../device-bringup/require-memory.md)）。
  最後に読む `usb_midi.rb`（コメント込み 4.3KB）はコンパイルにソースの約 6 倍の連続領域が要り、max_free 5.9KB では取れない、と見ている
