# upstream に入れた変更

この repo は [picoruby](https://github.com/picoruby/picoruby) のフォークで、
基板固有のものは新しいディレクトリに置いている。**upstream のファイルへの変更は
ここに全部載せる。** マージのときに何を見ればよいかが分かるように。

新規ディレクトリ（衝突しないもの）:
`mrbgems/picoruby-is31fl3729/`、`mrbgems/picoruby-pio-uart/`、`mrbgems/picoruby-syntax-highlight/`、
`sim/`、`dev-docs/`、`tools/`、`docker/`、`lib/picorubykaigi01*`、
`examples/`、`tasks/docker.rake`、`tasks/sim.rake`。

---

## 1. ビルドの入口

| ファイル | 変更 |
|---|---|
| `Rakefile` | `tasks/docker.rake`・`tasks/sim.rake`・`tasks/site.rake`（使い方のサイト。2026-10-03）を load する **3 行** |
| `build_config/r2p2-picoruby-pico2.rb` | `picoruby-is31fl3729`・`picoruby-pio-uart`・`picoruby-adc-capture`（ADC を DMA で録り続ける計測用の新規 gem。32KB の RAM を使う）を足し、`picoruby-keyboard` を外した（pico2_w と同じ構成に）。`picoruby-ssd1306`（I2C の OLED。SSD1315 にも使う。2026-09-27）を足した（pico2_w も同じ） |
| `tasks/picoruby/r2p2.rake` | `R2P2_CONSOLE_UART` 環境変数を cmake の `-D` に渡す **8 行** |
| `build_config/picoruby-wasm.rb` | シミュレータ用に描画・フォント gem と、コードの色付けの `picoruby-syntax-highlight`（新規ディレクトリ。family-mruby から無変更で持ってきた）を追加。`PICOBOARD_WASM` のときだけ。**`picoruby-is31fl3729` は最後に置く**（初期化で `require 'i2c'` が失敗し、それより後ろの gem が初期化されなくなるため） |

## 2. `build_config/r2p2-picoruby-pico2_w.rb` — gembox を削った

```ruby
- conf.gembox "networking"
- conf.gem core: 'picoruby-ble'
- conf.gem core: 'picoruby-ble-uart'
- conf.gem core: 'picoruby-keyboard'
+ conf.gem core: 'picoruby-is31fl3729'
+ conf.gem core: 'picoruby-pio-uart'
```

**理由。** 起動しただけでヒープが 290KB 使われていて、`/lib` のボードライブラリが
読めなかった。LED・音・ボタン・GROVE の学習用基板にネットワークと BLE は要らない。
削ると **220KB / 最大連続 161KB** になり、読めるようになる。
→ [device-bringup/require-memory.md](device-bringup/require-memory.md)

## 3. `picoruby-r2p2/ports/rp2040/fault_handler.c` — 固まらずに再起動する

末尾がこうだった:

```c
while (1) {
  __asm volatile("bkpt #0");
}
```

**`bkpt` はデバッガが halt しているときだけ止まる命令**で、繋がっていなければ
フォールトにエスカレートする。すでに HardFault の中なので **double fault**、
そしてロックアップ。SWD からメモリも読めなくなり、電源を抜くしかなくなる。
prod は stdio が無効なので、その上のレジスタダンプもどこにも出ていない。

変更:

- naked ハンドラの冒頭で SIO CPUID を見て `__StackTop` / `__StackOneTop` に
  MSP を積み直す（スタック溢れで来た場合にハンドラ自身が動けるように）
- `DHCSR.C_DEBUGEN` を見て、**デバッガが居るときだけ `bkpt`**。
  居なければ `stdio_flush()` して `watchdog_reboot(0, 0, 0)`

→ [device-bringup/flashing-from-wsl.md](device-bringup/flashing-from-wsl.md)

## 4. `picoruby-r2p2` — `/lib` とサンプルをファームで運ぶ

| ファイル | 変更 |
|---|---|
| `ports/rp2040/main.c` | `picorb_install_system_files()` の呼び出し **2 行** |
| `cmake/CMakeLists.txt` | `tools/gen_system_files.rb` を configure 時に走らせる |
| `ports/rp2040/system_files.{c,h}` | **新規**。無いファイルと古いファイルを書き出す |

**理由。** 配布は UF2 1 本にしたい。UF2 は 0x10000000〜0x10245900 で、littlefs は
0x10380000 なので、焼いてもファイルは届かない。ファームが内蔵して起動時に書く。

ウォッチドッグで囲ってある。**USB より前に走るので、そこで止まったボードは
何にも答えない**（littlefs が壊れていると `lfs_stat` が返らないことがある)。
次の起動でやりかけだと分かったら、丸ごと諦めてシェルまで進む。

## 5. `picoruby-vram` — 8bit 階調

| ファイル | 変更 |
|---|---|
| `src/vram.c` | `gray8` のピクセル関数 3 つと `display_page_init_format`、`display_draw_bytes` に色 |
| `src/mruby/vram.c` / `src/mrubyc/vram.c` | `layout: :gray8`、`draw_bitmap` / `draw_bytes` の `color:` |
| `sig/vram.rbs` / `README.md` | 上に追随 |
| `mrblib/vram.rb` / `test/vram_test.rb` | `VRAM::Delegatable` の `draw_bitmap` / `draw_bytes` が `color:` を受けて渡す（sig は足したのにラッパーが落としていて、型検査に 2 件出ていた。SSD1306 / UC8151 のように委譲するドライバでは色を指定できなかった）。gem に最初のテスト 4 本 |

**理由。** 1bit だと LED の明るさが使えず、サンプルが書きにくかった。
ピクセル形式は元から関数ポインタで切り替わる作りだったので、
**1 形式足すだけ**で済んだ。既存の `:vertical` / `:horizontal` は変わらない。

## 6. `picoruby-uart` — PIO のユニットを足した（**184 行**）

| ファイル | 変更 |
|---|---|
| `include/uart.h` | `#define PICORB_UART_PIO_UART0 2` と `UART_UNIT_MAX` を 2→3。**9 行** |
| `ports/rp2040/uart.c` | ユニットの追加。**175 行** |
| `picoruby-irq/include/irq.h` | `IRQ_SRC_UART2,` **1 行** |

```ruby
UART.new(unit: :PIO_UART0, txd_pin: 28, rxd_pin: 29, baudrate: 115_200)
```

**理由がこの変更の全部。** ピンマルチプレクサは UART の役割をピン番号で固定する
ので、同じ基板 2 枚をストレートケーブルで繋ぐと TX 同士がぶつかる。PIO なら
どちらのピンにどちらの役割も置けるので、片方だけ入れ替えれば噛み合う。

**それを別クラスにはしなかった。** この基板で覚えたことが素の R2P2 で
通じなくなるからで、それは教材として失敗だ。`gets` も `irq` も
`bytes_available` も `rx_overflow_count` も、**同じ `UART` の同じメソッド**が動く。
違うのは `unit:` に何を渡すかだけで、それは `RP2040_UART0` と `RP2040_UART1` を
選ぶのと同じ性質の指定。

### 変更の中身

`picoruby-uart` は**コアとポートが分離**されている。

```
ポート ── UART_pushBufferAt ─▶ コアのリングバッファ ─▶ read/gets/getbyte/bytes_available
      └── UART_signal_rx ───▶ イベント橋 ────────▶ irq
```

だからポートにユニットを 1 つ足すだけで全メソッドが動く。足したもの:

- **エンジンへの weak な入口。** 実装は `mrbgems/picoruby-pio-uart`。
  weak なので、**その gem を積まないビルドもそのままリンクでき**、
  ユニットを要求すると「使えない」と答える
- 名前 `"PIO_UART0"` の解決。ピン表の検査は**通さない**（どのピンでもよいのが
  PIO の取り柄なので、表に載っていないことは意味を持たない）
- `UART_open` の分岐と、**プロデューサ**
- ハード固有の操作（`set_format` / `set_flow_control` / `break`）の分岐。
  PIO は 8N1 のみでフロー制御は無いので、既定以外は静かに適用されない

### プロデューサ

ハードウェア UART は割り込みでリングを埋める。PIO には DMA があるが、
**DMA は転送が終わるまで何も上げず、この転送は終わらない**。
そこでハードウェアアラームで 1ms ごとに DMA リングからコアのリングへ移し、
`UART_signal_rx` を打つ。これで `UART#irq` がハードウェアユニットと同じに見える。

**1ms は遅延であって欠落ではない。** DMA リングは誰も汲みに来なくても
512 バイト持っている——それが DMA にした理由そのもの。

アラーム番号は `hardware_alarm_claim_unused()` で取る。**0 は
picoruby-machine のティック、1 と 2 は picoruby-psg、3 は SDK の既定
アラームプール**で、埋まっている番号を `hardware_alarm_claim()` すると panic する。

→ [grove-link/report.md](grove-link/report.md)

## 7. `picoruby-machine` — コンソールを UART にも出す（**61 行**）

| ファイル | 変更 |
|---|---|
| `ports/rp2040/machine.c` | `R2P2_CONSOLE_UART` が定義されていれば、`picorb_hal_write` が UART にも書き、UART の受信割り込みが `picorb_hal_stdin_push` に流す |
| `picoruby-r2p2/cmake/CMakeLists.txt` | `option(R2P2_CONSOLE_UART ... OFF)` **8 行** |

r1 基板は USB が死んでいる（[device-bringup/r1-board.md](device-bringup/r1-board.md)）ので、
J2 の UART からシェルに触るために足した。**既定は OFF** で、素の R2P2 と同じ
CDC だけの動作。ON にしたビルドでは UART0 とその IRQ をコンソールが取るので
`UART.new(unit: :RP2040_UART0)` は使えない（PIO の `:PIO_UART0` は無事）。

## 8. `picoruby-irq` — エッジのデバウンスを作り直し、同じピンの登録を置き換えにした

| ファイル | 変更 |
|---|---|
| `src/irq_debounce.c` | **新規**。ポートに依存しないデバウンスの状態機械 |
| `include/irq.h` | 上の宣言と、posix 用の模擬の宣言 |
| `ports/rp2040/irq.c` | `debounce` 付きのエッジ登録は両エッジを有効にし、状態機械とアラームで判定する |
| `ports/posix/irq.c` | GPIO 割り込みの模擬（ハンドラ表・キュー・デバウンス・ms 時計） |
| `src/mruby/irq.c` / `src/mrubyc/irq.c` / `sig/irq.rbs` | posix だけ `IRQ.simulate_gpio` / `IRQ.simulate_elapse` |
| `test/irq_gpio_debounce_test.rb` | **新規** |
| `mrblib/irq.rb` / `sig/irq.rbs` | GPIO の登録で、同じピンの既存の登録を外してから登録する。置き換えられた登録の `unregister` は `false` |
| `test/irq_gpio_registration_test.rb` | **新規** |
| `README.md` | 上の 2 つの動作を追記 |

**理由。** 元の判定は「前回と同じ種類のイベントなら捨てる」で、タクトスイッチの
チャタリングを両エッジでも FALL だけでも取れなかった（ボタン 1 回が 2 回に数えられる）。
また、シェルで流したスクリプトの登録が残り、流し直すと同じピンの割り込みが新しい方に届かなかった。
upstream に PR を送る前提で、基板に依存しない形で書いている。esp32 のデバウンスは未修正。
→ [upstream-issues.md](upstream-issues.md)

---

## 触っていないもの

`mrbgems/` 自体はサブモジュールではない（サブモジュールは中の特定 gem だけ）。
`picoruby-pio`、`picoruby-i2c`、`picoruby-shell`、`picoruby-require` などは
**一切変更していない**。

`picoruby-require` が `Sandbox` を回収しないのは把握しているが、
**upstream の仕様変更になるので触っていない**。サンプル側で
`require` 1 本ごとに `GC.start` を呼んで凌いでいる。
→ [device-bringup/require-memory.md](device-bringup/require-memory.md)

⚠️ `tasks/picoruby/r2p2.rake` はボード名を決め打ちでループしてタスクを生成する。
独自ボード名を足すにはここに手を入れる必要があり、**まだ手を入れていない**
（`USE_WIFI=1` もここでボード名ごとに決め打ちされている）。

## 9. `picoruby-machine` — 眠っているあいだ周辺回路のクロックを止めない（**−22 行**）

| ファイル | 変更 |
|---|---|
| `ports/rp2040/machine.c` | `picorb_hal_init` の `clocks_hw->sleep_en0 = 0;` と `sleep_en1 = ...` の代入を**消した**（リセット値の全 ON のまま）。関連するコメント 2 か所を追随 |

消す前は、Ruby のタスクが全部待っているあいだ（`__wfi`）PWM・DMA・PIO・I2C・SPI・ADC のクロックが止まっていた。
音声の PWM が 1ms ごとに 27µs しか進まず、スピーカーの「ざらざら」の原因だった。
「必要な回路だけ残す」ではなく全部残したのは、学習用の基板で、使った回路が黙って止まる事故を避けるため。
経緯は [audio-quality/report.md](audio-quality/report.md)、問題の記録は [upstream-issues.md](upstream-issues.md) の 3。

## 10. `picoruby-littlefs` / `picoruby-psg` — フラッシュに書くあいだ core1 を待たせる

| ファイル | 変更 |
|---|---|
| `picoruby-littlefs/ports/rp2040/flash_hal.c` | 書き込み・消去の 3 か所を `flash_guard_enter/exit` で包む。core1 が `multicore_lockout_victim_init()` 済みなら `multicore_lockout_start_blocking()` で止めてから割り込みを禁止する。core1 が動いていなければ今までどおり |
| `picoruby-psg/ports/rp2040/psg_port.c` | core1 の入口で `multicore_lockout_victim_init()`。停止の依頼（`CMD_CLEANUP`）をコア間 FIFO から `volatile` のフラグに変えた（SDK のロックアウトが core1 の FIFO 受信を割り込みで握り、知らない値を捨てるため） |

PSG が core1 でフラッシュ上のコードを実行している最中にファイルを書くと、core1 が二重フォールトで固まっていた。
シミュレータの [実機で実行] は毎回 `/home/app.rb` に書くので、PSG のスクリプトを 2 回流すと実機が応答しなくなった。
書いているあいだ（1 回数十 ms）core1 が止まるので、再生中に書くと音が途切れる。
問題の記録は [upstream-issues.md](upstream-issues.md) の 4。

## 11. `picoruby-psg` — PWM のキャリアを 22.5kHz → 約 132kHz に

| ファイル | 変更 |
|---|---|
| `ports/rp2040/psg_drv_pwm.c` | DMA 版: 分周なし、`TOP = clk_sys / (22050 × 6) − 1`（150MHz で 1132）。1 サンプルを PWM 6 周期ぶん DMA で書く。4096 段 → 1133 段に減る分の端数は 6 周期に配って平均を保つ |

元は 1 サンプル = PWM 1 周期で、キャリアが可聴域のすぐ上（22.5kHz）にあり、基板の RC フィルタ（146kHz 前提）を
ほぼ素通りしていた。分周比の小数部が SDK で切り捨てられて再生が 22,536Hz（約 38 セント高い）になる件も、
分周をやめたので解消（22,065Hz）。DMA の張り直しが 1 周期遅れても、同じ値の 7.5µs の保持で済む。
非 DMA 版（`PICORUBY_PSG_PWM_DMA=0`）は変えていない。

DMA は **2 チャンネルを互いに `chain_to` でつないで交互に使う**。1 チャンネルをソフトで張り直すと、かたまり（64 サンプル）の
境目ごとに PWM 2 周期ぶん足踏みした（J6 の実測で 440Hz が 438.0Hz、−0.5%。毎秒 344 回の位相の段差）。
空いているほうのチャンネルに次のかたまりを先に積んでおき、切り替えはハードに任せる。

`ports/common/psg.c` の三角波の折り返しも直した（[upstream-issues.md](upstream-issues.md) の 5）。

## 12. `picoruby-psg` の出力を中央基準に、`picoruby-midibase-mml` の `Player#stopped?`

| ファイル | 変更 |
|---|---|
| `picoruby-psg/ports/common/psg.c` / `include/psg.h` | 各声を 0 を中心に上下へ振り、合計を中央（2048）に載せる。中央へはリセット後 約 93ms かけて上がる。固定音量（エンベロープなし）の変化は約 3ms かけて追従させる。ソフトクリップは上下対称に。止まっているトーン（`tone_inc == 0`）は無音扱い |
| `picoruby-midibase-mml/mrblib/player.rb` | `run` が最後まで再生して抜けるときに `@stopped = true`（**1 行**）。`stopped?` で待つ呼び出し側が永久に待っていた |

元の出力は片側（0 〜 振幅）で、音が鳴る・止まるたびに平均電圧が振幅の半分だけ動き、出力のカップリングコンデンサを通って
「ブチッ」と鳴っていた。1 声の振幅（山から谷まで）は変えていない。
この repo 側では `lib/picorubykaigi01/speaker.rb` の `play_mml` がアンプを切らずに前の曲だけ止めるようにした（`stop` は今までどおりアンプも切る）。

## 13. `picoruby-psg` — core1 の音声処理を RAM に置き、debug ビルドでも最適化する

| ファイル | 変更 |
|---|---|
| `include/psg.h` | `PSG_HOT`（`optimize("O2")` + `.time_critical.psg` セクション）と `PSG_HOT_DATA` を定義。rp2040 / rp2350 以外では空 |
| `ports/common/psg.c` | レンダリング（`PSG_render_block` とその下請け）、パケット処理（`PSG_process_packet` / `PSG_write_reg` / `PSG_rb_peek` / `PSG_rb_pop`）、`PSG_tick_1ms` に `PSG_HOT`。表 3 つ（`vol_tab` / `pan_tab_l` / `pan_tab_r`）に `PSG_HOT_DATA` |
| `ports/rp2040/psg_port.c` | `psg_core1_main`、`tick_cb`、`psg_process_packets`、`PSG_enter_critical` / `PSG_exit_critical` などに `PSG_HOT` |
| `ports/rp2040/psg_drv_pwm.c` | `psg_pwm_write_buffer` / `psg_pwm_pack_sample` に `PSG_HOT`。SDK の DMA アクセサ（`-O0` ではフラッシュ上の関数として残る）をやめてレジスタを直接書く。番兵バッファ（`dma_buf[2]`）をゼロではなく中央の値で埋める |

元は debug ビルド（`-O0`）で、各音のあたまに短いノイズが入っていた。core1 が 1 かたまり（64 サンプル = 2.88ms）を作って DMA に積むのに
平均 1.6ms かかり、core0 が Ruby を実行している時間帯に締め切りを越えていた（10 秒に 166 回）。RAM の消費は約 3.2KB。
数字と経緯は [audio-quality/report.md](audio-quality/report.md) の §3「その 6」、問題としての記録は [upstream-issues.md](upstream-issues.md) の 6。
RP2040 のボード（pico / pico_w）でも同じ 3.2KB を RAM に取る点は、upstream に出すなら相談が要る。

## 14. `picoruby-psg` — エンベロープを全チャンネル同じ速さで進める

| ファイル | 変更 |
|---|---|
| `ports/common/psg.c` | `update_envelope` のループ内の `return` 4 か所を `continue` に（とコメント 3 行） |

問題の記録は [upstream-issues.md](upstream-issues.md) の 7。

## 15. USB MIDI 版のビルド（`R2P2_USB_MIDI`、2026-11-01）

基板を PC から USB MIDI 楽器として鳴らすための**別のビルド**。`R2P2_USB_MIDI=1` を付けたときだけ効き、
付けないビルドは USB の構成も gem も変わらない。設計と経緯は [usb-midi/README.md](usb-midi/README.md)。

| ファイル | 変更 |
|---|---|
| `build_config/r2p2-picoruby-pico2.rb` | `ENV['R2P2_USB_MIDI']` のときビルド名に `-midi` を足し、`picoruby-usb_midi_device`（MIDIBASE のトランスポートにするファイルを足す）・`picoruby-adventure_board-usb_midi`（`UsbMidi` を焼き込む。メモリのため。[usb-midi/README.md](usb-midi/README.md) の「メモリ」）を `conf.gem` |
| `tasks/picoruby/r2p2.rake` | `r2p2_usb_midi?` / `r2p2_variant` / `r2p2_def_usb_midi`。ビルドディレクトリ・libmruby の名前に `-midi`、cmake に `-D R2P2_USB_MIDI` |
| `picoruby-r2p2/cmake/CMakeLists.txt` | `option(R2P2_USB_MIDI)`。`R2P2_USB_MIDI` / `USB_MIDI_DEVICE_ENABLED` / `USB_MIDI_DEVICE_OWN_DESCRIPTORS=0`（gem のディスクリプタではなく R2P2 のものを使う）を定義し、`gen_system_files.rb` に `--usb-midi` を渡す |
| `picoruby-r2p2/include/tusb_config.h` | `R2P2_USB_MIDI` のとき `CFG_TUD_MIDI 1`。MIDI の FIFO を 64 byte ずつ |
| `picoruby-r2p2/ports/rp2040/usb_descriptors.c` | `CFG_TUD_MIDI` のとき IAD + `TUD_MIDI_DESCRIPTOR`（インターフェース 9・10、EP 0x0A / 0x8A、文字列 10 "PicoRuby MIDI"）。PID を 0x401F に（既存の `_PID_MAP` では HID×3 が MIDI のビットを既に立てていて 0x400F のまま変わらないため） |
`picoruby-machine` は**変えていない**。TinyUSB を呼んでよいのは USB pump の `tud_task()` の中だけなので、
最初は pump にフックを足したが、TinyUSB 自身の `usbd_defer_func()`（関数呼び出しを `tud_task()` のキューに積む）で
代わりが利くので取り下げた。

新規（衝突しない）: `mrbgems/picoruby-usb_midi_device/`（kirikak2 のサブモジュール。MIDoRI と共有。
RP2 の port を `ports/rp2040/` に、MIDIBASE のトランスポートにするファイルを `mrblib_midibase/` に足した）、`mrbgems/picoruby-adventure_board-usb_midi/`、`lib/adventure_board/usb_midi.rb`、
`examples/usb_midi/`。
