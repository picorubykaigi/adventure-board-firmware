# ライブラリ

`AdventureBoard` は、基板の部品をプログラムから使うためのライブラリです。
基板の `/lib/adventure_board.rb` と `/lib/adventure_board/` に入っています。
コンソールの「▸ ライブラリのコードを見る」でも同じものが読めます。

```ruby
require 'adventure_board'
GC.start

matrix = AdventureBoard.matrix     # 使う部品だけを取り出す
```

部品は、最初に取り出したときに読み込まれます。

| 取り出し方 | 部品 |
|---|---|
| `AdventureBoard.matrix` | [LED マトリクス](#ledmatrix) |
| `AdventureBoard.buttons` | [ボタン](#buttons) |
| `AdventureBoard.speaker` | [スピーカー](#speaker) |
| `AdventureBoard.status_led` | [ステータス LED](#statusled) |
| `AdventureBoard.grove_i2c` | [GROVE1 の I2C](#grove) |
| `AdventureBoard.grove_link(role:)` | [GROVE2 で基板どうしをつなぐ](#grove) |
| `AdventureBoard.grove_uart` | [GROVE2 の UART](#grove) |

## LedMatrix

16×16 の LED マトリクスです。

### 1 つずつ光らせる

座標は `(1, 1)` 〜 `(16, 16)`、明るさは 0〜255 です（見た目に比例するよう補正されます）。

| 命令 | 動作 |
|---|---|
| `set(x, y, 明るさ = 255)` | 1 つの明るさを決めます |
| `clear` | 全部消します |
| `fill(明るさ = 255)` | 全部を同じ明るさにします |
| `show` | ここまでの変更を LED に送ります。**これを呼ぶまで光りません** |
| `brightness = 値` | 全体の明るさの上限を決めます（0〜0x40、最初は 0x20）。上げると使用する電力が増えます |

### 描く

座標は `(0, 0)` 〜 `(15, 15)` です。描いたあと `blit` で LED マトリクスに写し、`show` で送ります。

| 命令 | 動作 |
|---|---|
| `clear_drawing` | 描く場所を消します |
| `set_pixel(x, y, 明るさ)` | 点を描きます |
| `draw_line(x1, y1, x2, y2, 明るさ)` | 線を描きます |
| `draw_rect(x, y, 幅, 高さ, 明るさ)` | 四角の枠を描きます |
| `draw_text(文字, x = 0, y = 0, font: "go16")` | 文字を描きます。フォントは `"go16"`（ゴシック）`"min16"`（明朝）`"go12"` `"min12"` `"maru12"`（12 ドット）から選べます |
| `pen = 明るさ` | 明るさを省いたときと、文字の明るさを決めます |
| `blit` | 描いたものを LED ドライバにコピーします |

## Buttons

6 つのボタンです。名前は `:up` `:down` `:left` `:right` `:a` `:b` です。
チャタリングへの対応も含まれています。

| 命令 | 応答 |
|---|---|
| `each_press { \|name\| ... }` | 押されたボタンを古い順に 1 つずつ |
| `take_press` | 押されたボタンを 1 つ。無ければ `nil` |
| `presses_waiting` | まだ取り出していない数 |
| `clear_presses` | 覚えている押下状態を捨てます |
| `pressed?(name)` | いま押されているか |
| `pressed` | いま押されているボタンの一覧 |
| `any?` | どれか 1 つでも押されているか |

## Speaker

音をスピーカーで鳴らす機能です。この機能では音は 3 つまで重ねられます。

| 命令 | 動作 |
|---|---|
| `reset` | 音量・音色などを最初の状態に戻します。音を鳴らすプログラムの最初に呼びます |
| `play_mml(mml, loop: false)` | MML の曲を鳴らします。配列で渡すと同時に鳴らします（3 つまで）。`loop: true` にすると、MML の `$` の位置から最後までをくり返します（`$` が無いとくり返しません） |
| `playing?` | 曲が鳴っているか |
| `stop` | 止めます |
| `note_on(番号, velocity: 100)` | 1 音鳴らし始めます。60 が MML の `o4 c`（約 262Hz のド）です |
| `note_off(番号)` | その音を止めます |

MML の書き方は [チュートリアル 5](/tutorial/05-sound#mml) を見てください。

## StatusLed

USB の近くの緑の LED を操作します。

| 命令 | 動作 |
|---|---|
| `on` / `off` | 点灯・消灯 |
| `toggle` | 点いていれば消し、消えていれば点けます |
| `on?` | 点いているか |

## GROVE

| 命令 | 応答 |
|---|---|
| `AdventureBoard.grove_i2c(frequency: 100_000)` | GROVE1 の `I2C`（GPIO6 / GPIO7）。I2C のセンサなどに |
| `AdventureBoard.grove_uart(baudrate: 115200)` | GROVE2 の `UART`（TX = GPIO28、RX = GPIO29） |
| `AdventureBoard.grove_link(role: :a)` | GROVE2 で同じ基板どうしをつなぎます。2 枚で `:a` と `:b` に分けます。ケーブルは、赤（電源）の線だけを切った Grove ケーブルを使ってください |

::: warning 今のファームウェア（2026.10.25 版）では grove_uart が使えません
この版は UART0 を R2P2 のシェル用に使っているので、`grove_uart`（や `UART.new(unit: :RP2040_UART0, ...)`）を呼ぶと基板が再起動します。
代わりに、下の「[GROVE2 の UART を PIO で使う](#grove-pio-uart)」の書き方を使ってください。
次の版のファームウェア（準備中）で、`grove_uart` も使えるようになる予定です。
:::

`grove_i2c` と `grove_uart` が返すのは、PicoRuby の [`I2C`](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-i2c) と [`UART`](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-uart) のオブジェクトそのものです。
ピンの番号を指定しなくてよいだけで、使えるメソッドは PicoRuby と同じなので、くわしくはリンク先の説明（英語）を見てください。

```ruby
i2c = AdventureBoard.grove_i2c
i2c.scan                         # つながっているデバイスのアドレスを表示
i2c.write(0x5F, 0x00)            # アドレス 0x5F に送る
data = i2c.read(0x5F, 1)         # アドレス 0x5F から 1 バイト読む
```

`grove_link` の使い方は、サンプルの一覧の「実機専用」にある「基板 2 枚をつなぐ」を見てください。

### GROVE2 の UART を PIO で使う {#grove-pio-uart}

今のファームウェア（2026.10.25 版）で GROVE2 の UART を使うときは、`UART.new` に `unit: :PIO_UART0` を渡します。
ハードウェアの UART の代わりに、PIO（RP2350 のプログラムできる入出力）で UART を作ります。
返ってくるのはふつうの `UART` なので、`write` / `read` / `gets` / `bytes_available` などはそのまま使えます。

```ruby
uart = UART.new(
  unit: :PIO_UART0,   # ハードウェアの UART0 の代わりに PIO を使う
  txd_pin: 28,        # 送信
  rxd_pin: 29,        # 受信
  baudrate: 115200
)

uart.write("hello\r\n")   # 相手に送る

while true
  n = uart.bytes_available
  if n > 0
    print uart.read(n)    # 届いた分だけ読んで表示する
  end
  sleep_ms 10
end
```

- 形式は **8N1（データ 8 ビット、パリティなし、ストップ 1 ビット）だけ**です。`data_bits:` などを変えても効きません。フロー制御（RTS / CTS）もありません
- 相手の機器と送受信が逆なら、`txd_pin` と `rxd_pin` を入れ替えます
- PIO の UART は 1 つだけで、`grove_link` も同じものを使います。同時には使えません
- 次の版のファームウェアからは `grove_uart` も使えますが、この書き方もそのまま動きます

## そのほか

PicoRuby の部品も、そのまま使えます。使い方は PicoRuby の各ライブラリの説明（[mrbgems](https://github.com/picoruby/picoruby/tree/master/mrbgems)）を見てください。

| | |
|---|---|
| `GPIO.new(番号, GPIO::OUT)` / `GPIO::IN \| GPIO::PULL_UP` | GPIO（[チュートリアル 7](/tutorial/07-breadboard)、[picoruby-gpio](https://github.com/picoruby/picoruby/tree/master/mrbgems/picoruby-gpio)） |
| `sleep_ms(ミリ秒)` | 指定した時間スリープ |
| `Machine.uptime_us` | 起動してからの時間（マイクロ秒） |
| `rand(n)` | 0〜n-1 の乱数 |
