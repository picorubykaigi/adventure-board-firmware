# 実機専用サンプル

シミュレータが持っていないハードを使うサンプル。**実機でのみ動く。**

ブラウザで動くサンプルは [`../sim/examples/`](../sim/examples/) にある。
こちらもシミュレータのページの一覧に「実機専用（シミュレータでは動かない）」として並ぶ。
読んだり書き換えたりして、「実機で実行」で基板に送れる。読み込んだままのコードで Run を押すと、
シミュレータでは走らせずに、実機専用だと案内する。

| ファイル | 使うもの | 必要なもの |
|---|---|---|
| [grove_link_chat.rb](grove_link_chat.rb) | GROVE-B（PIO で作った UART） | 基板 2 枚と、**赤（電源）の線だけを切った Grove ケーブル** |
| [envelope.rb](envelope.rb) | PSG のエンベロープ（MML の `s` / `m`）。減衰・トレモロ・和音を順に鳴らす | 基板 1 枚。シミュレータの音源には無い機能 |
| [oled.rb](oled.rb) | I2C の OLED（SSD1306 / SSD1315、128×64）に文字を出し、ボールを跳ねさせる。`picoruby-ssd1306` | OLED 1 枚。ブレッドボードで J1 の 02（SDA、GPIO2）/ 03（SCL、GPIO3）/ 3V3 / G につなぐ |

ハードウェア UART で 2 枚を繋ぐ `grove_uart_chat.rb`（クロスケーブルが要る）もあったが、2026-10-25 に消した。
配布物にクロスケーブルが無く、一覧に「2 枚をつなぐ」が 2 つ並ぶと迷うため。

## game.mrb（対戦ゲーム）

コンソールの「高度な機能」の［対戦ゲームを実機の app.mrb にする］が、これを実機の `/home/app.mrb` に送る（ファイルがあるときだけボタンが出る）。
ライブラリを `require` すると実機のメモリが足りないので、**ゲームと、使うライブラリの部品をまとめて 1 本の .mrb にしたもの**を置く。

- 中で `require 'adventure_board'` を呼ばない（呼ぶと実機の `/lib` を読んでコンパイルし、まとめた意味がなくなる）
- 実機のファームと同じコンパイラで作る（`RITE0400`）。コンソールは、先頭の版がページのコンパイラと違えば送らない
- 中に入れたライブラリはその時点のもので固まる。`lib/` を直したら作り直す
- 作り方の例: `docker compose -f docker/compose.yml run --rm shell bash -lc "rake && build/host/bin/mrbc -o examples/game.mrb ゲーム.rb"`
- **まだ置いていない**（対戦ゲームの .mrb は別にコミットされる予定）。無いあいだはボタンが出ない。
  試すなら `tools/game-mrb/hello_game.mrb`（「hello game」を表示し続けるだけ）を `examples/game.mrb` に写す
- 実機の `/home/examples` には入らない（ファームが書き出すのは `.rb` だけ）

## 動かし方

R2P2 のシェルから直接:

```
/home/examples/grove_link_chat.rb
```

シェルはパスで実行する。`grove_link_chat.rb` とだけ打っても、`PATH` は
`/bin` しか見ないので見つからない。

ファイルを送るには、ブラウザから WebSerial で（`dev-docs/webserial-console/`）か、
シェルの `vim` で書く。

## ⚠ GROVE-B のクロスケーブル

GPIO28 は UART0 TX、GPIO29 は UART0 RX にしかなれない
（ファンクション mux が UART の役割をピン番号の 4 の剰余で固定している。
28%4=0 が TX、29%4=1 が RX で、入れ替える選択肢が無い）。

したがって**同じ基板 2 枚をストレートケーブルで繋ぐと TX 同士がぶつかる**。

これを避けるために `grove_link_chat.rb` は PIO で UART を作り、片方の基板だけ
TX と RX を入れ替える。ピンの役割を選べるのが PIO の取り柄で、そのぶん
信号線を交差させたケーブルが要らない。ただし赤（電源）の線は切っておく（2 台の 3.3V どうしがつながるため）。設計は [dev-docs/grove-link/](../dev-docs/grove-link/)。

ハードウェア UART（`AdventureBoard.grove_uart`）で 2 枚を繋ぐなら、信号 2 本を入れ替えたケーブルが要る
（Seeed **Grove - UART Crossover Cable 4Pin**、SS100052406 など）。
J5 は、Grove ケーブルの **黄=GPIO29(RX) / 白=GPIO28(TX) / 赤=3V3 / 黒=GND** につながる
（PV1 と量産版。r1 は並びが逆だった）。クロスケーブルは黄と白だけが入れ替わっているものを選ぶこと。
電源と GND が入れ替わる製品を掴むと危険。
