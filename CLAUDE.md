# adventure-board-firmware

PicoRuby のフォーク。**Adventure Board**（基板リポジトリでの名前は Adventure Board。
RP2350A / 16×16 LED マトリクス / 音声 / ボタン / GROVE、PicoRubyKaigi 2026 の学習用配布基板）のファームウェアを作る。

リポジトリは `github.com/picorubykaigi/adventure-board-firmware`（2026-09-23 に `kishima/picorubykaigi01-board-firmware` から移した。
ブランチは `main`。upstream の picoruby は `upstream` リモートから merge する）。ローカルのディレクトリ名は移行前のまま。

手元の基板は **PV1**（2026-10-03 着）と試作基板 r1。どちらも **Pico 2 相当、WiFi なし**。焼くのは `pico2` ビルド。
**PV1 は USB がそのまま使える**ので、BOOTSEL + UF2 のドラッグ&ドロップで焼く（[pv1-board.md](dev-docs/device-bringup/pv1-board.md)）。
r1 で問題だった USB 接続と音は、PV1 でも問題ないことを確認済み。
基板の設計は 2026-10-03 に**量産版 V1** になり、**2026-10-04 に発注、2026-10-19 に届いた**（1 枚で FW・LED マトリクス・スピーカーを確認済み）。本番（2026-10-31）まではドキュメント（`site/`）とコンソール（`sim/`）の仕上げ。PV1 との違いは下側の取付穴の位置と、シルクの "PV1" を消しただけ
（回路・部品配置は同じなので、PV1 で確かめたことは V1 にもそのまま当てはまる）。KiCad のファイルは `adventure-board.kicad_pcb` に改名された。
r1 の USB は元は死んでいたが、手で配線して USB シリアルが使えるようになっている（Windows 側では 16c0:400f、CDC が複数）。
書き込みと UART コンソールは J2 の Debug Probe から、ブラウザの WebSerial は USB から。**USB 側は WSL に attach しない**。
**手順書: [dev-docs/device-bringup/probe-workflow.md](dev-docs/device-bringup/probe-workflow.md)**
（経緯は [r1-board.md](dev-docs/device-bringup/r1-board.md)）。
基板が来るまでの開発機は **Raspberry Pi Pico 2 W** だった。

ライブラリ実装そのものの規約（サブモジュール、ブロック反復の回避、メモ化、
WebAssembly の注意）は [AGENTS.md](AGENTS.md) にある。こちらは**この repo 固有の
作業手順と、実際に踏んだ落とし穴**をまとめたもの。

## ビルドは全部 Docker

**ホストで実ビルドを走らせないこと。** ホストの ruby は 3.2.6 で、
README が要求する 3.4+ に満たない。ホストの `rake` は
タスク定義の読み込みには足りるので、`docker:*` と `sim:*` の起動には使える。

```console
rake docker:image                          # イメージを作る（無ければ自動で作られる）
rake docker:r2p2:picoruby:pico2_w:prod     # ビルド → dist/{vm}-{board}-{mode}/
rake docker:r2p2:picoruby:pico2_w:debug    # gdb 用 .elf 付き
rake docker:r2p2:picoruby:pico2_w:clean
rake docker:shell                          # コンテナ内シェル
R2P2_CONSOLE_UART=1 rake docker:r2p2:picoruby:pico2:debug   # r1 基板用: シェルを J2 の UART にも出す
rake docker:clean                          # イメージと bundle ボリュームを消す
```

`build_config/r2p2-*.rb` が存在する `{vm}:{board}:{mode}` の組み合わせだけ
タスクが生成される。詳細は [docker/README.md](docker/README.md)。

### 書き込み（PicoProbe / SWD）

```console
rake docker:flash:picoruby:pico2_w:prod
```

イメージに `raspberrypi/openocd`（`sdk-2.0.0`）を同梱してある。Debian の 0.12.0 は
RP2350 非対応で `target/rp2350.cfg` が無いため。openocd は `.uf2` ではなく
**`.elf` を焼く**。

Windows 側でプローブを WSL へ渡す（挿すたびに 1 回）:

```powershell
usbipd list
usbipd attach --wsl --busid <BUSID>
```

⚠️ **実基板の J2（SWD/UART ヘッダ）は DNP** で JLCPCB では実装されない。
PicoProbe を使うにはピンヘッダを自分で付ける。BOOTSEL は実装されるので
UF2 のドラッグ&ドロップは常に使える。

### USB の無い基板を Debug Probe だけで触る（r1 の標準手順）

手順書は [dev-docs/device-bringup/probe-workflow.md](dev-docs/device-bringup/probe-workflow.md)。要約:

```console
usbipd attach --wsl --busid 1-5                              # Windows 側。挿すたびに 1 回
R2P2_CONSOLE_UART=1 rake docker:r2p2:picoruby:pico2:debug   # シェルを J2 の UART にも出す
rake docker:flash:picoruby:pico2:debug
export R2P2_PORT=/dev/ttyACM0                                # 以後 r2p2dev.py はこの tty を使う
tools/r2p2dev.py watch 30                                    # 起動ログ。Starting shell... まで何も送らない
tools/r2p2dev.py run 'ls /lib' 'free'
tools/r2p2dev.py push local.rb /home/x.rb                    # dfucli 経由。irb は使わない
```

- J2: 1=GND 2=SWCLK 3=SWDIO 4=UART_RX(GPIO1)←Probe TX 5=UART_TX(GPIO0)→Probe RX
- **`reset` や書き込みの直後にコンソールへ送らない。** Debug Probe が USB ごと固まり、抜き差しでしか戻らない
- この基板では openocd の halt が効かない。gdb は当面使えない。焼く・読む・書くは通る
- ハードを疑うときは、短いスクリプトを `push` して 1 トランザクションずつ成否を出し、書いたら読み戻す

## テスト

```console
# gem 単体（コンテナ内で）
docker compose -f docker/compose.yml run --rm shell rake 'test:gems:picoruby[picoruby-is31fl3729]'

# 型検査（Steepfile が **/sig/ を自動で拾う）
docker compose -f docker/compose.yml run --rm shell bundle exec steep check --log-level=fatal
```

## LED シミュレータ（実機なしで動かす）

ブラウザで実ドライバを動かし、16×16 の光り方を確認する。
[sim/README.md](sim/README.md) と [dev-docs/wasm-simulator/](dev-docs/wasm-simulator/)。

```console
rake sim:wasm               # フォント・描画 gem 入りの PicoRuby.wasm を作る（要 emsdk）
rake sim:test               # 中核のヘッドレス検証（ブラウザ不要）
rake sim:check              # ヘッドレス Chromium でページを操作して結果を報告
rake sim:check[01_light]    # サンプル 1 つだけ
rake sim:server             # 手で見るとき → http://localhost:8080/sim/
rake sim:board_art          # 基板の絵と位置の表を .kicad_pcb から作り直す（kicad/kicad:9.0-full、約 5GB）
```

`sim:check` は canvas を読み戻して **16×16 のテキスト**にするので、
目視ではなく機械的に判定できる。console 出力・ページエラーも報告し、
スクリーンショットは `tmp/browser-check/`（git 管理外）に残る。
ブラウザ用は**ファーム用とは別のイメージ**（`docker/browser.Dockerfile`）。

漢字・図形を出すには `rake sim:wasm` でローカルの wasm が要る
（stock の `@picoruby/wasm-wasi` に `picoruby-vram` / `-shinonome` が入っていないため）。
**emsdk はホストの `~/emsdk` をコンテナにマウントして使う**（イメージには入れない）。
`sim/vendor/` が無ければ CDN にフォールバックするので、ビルド無しでも動く。

## ハード仕様の正

| 順位 | 資料 |
|---|---|
| 1 | `tmp/picorubykaigi01-board/`（基板リポジトリの clone。`.kicad_pcb` / production / docs）。量産版の製造データは `production/v1/` |
| 1 | **公開版** `github.com/picorubykaigi/adventure-board-pcb`（2026-10-19 公開、CERN-OHL-P v2）。上の clone とは別の履歴で、設計データと `production/` だけを置いている。回路図を直したら両方に入れる |
| 1 | `ref/picorubykaigi01-board/production/r1/`（netlist / positions / 回路図 / BOM） |
| 1 | `ref/.../docs/PicoBoard_BOM_pin_assignment_20260824.xlsx`（`.kicad_pcb` から機械抽出） |
| 2 | `ref/external_info/data_sheet/IS31FL3729.pdf` |
| ✗ | `ref/.../docs/gpio_assignment.md` — **失効**。2026-08-18 の改訂で GPIO が入れ替わった |
| ✗ | `ref/.../docs/led_research_results.md` — 調査段階。LED は赤0603 → **白0402 に変更済み** |

抽出済みの要点は [dev-docs/led-matrix-gem/hardware.md](dev-docs/led-matrix-gem/hardware.md)。
`ref/` は git 管理外。

**間違えやすい点:**

- **SDB は GPIO24**（GPIO14 ではない）。**H にしてから 200µs 待って**最初の I2C
- **U11 は列が左右反転**（`cs = 17 - x`）。上半分 U10=0x34 / 下半分 U11=0x35
- **全点灯 + 音声で USB 500mA を超える。TPS2065 は 1A まで落ちないのでハードは守ってくれない**
- **IS31FL3729 は LGC を 0→1 にした直後の 1 トランザクションを必ず落とす**（データシート
  に無い。実チップで確認）。gem が `configure` で捨て読みを入れて吸収しているので、
  レジスタを直接叩くとき以外は気にしなくてよい
- **xlsx のボタン名は間違っている。** 正しいのはシルク印字: SW1=UP(GPIO17) /
  SW2=LEFT(18) / SW3=RIGHT(19) / SW4=DOWN(20) / SW5=B(21) / SW6=A(22)。
  xlsx は SW2〜SW6 を ↓ ← → A B としている。r1 で押して確認済み
- **MML のイベントは同じ時刻でも 1 つずつ Ruby で処理される**（debug ビルドで設定 1 つ 40〜60ms、`note_on` 20〜30ms）。
  複数トラックの先頭に設定（`s` `m` `@` `v` など）と音を続けて書くと、和音がばらける。設定のあとに短い休符を置く
- **スピーカーは PSG の左出力（GPIO10）だけ。** パンは `Speaker` が左いっぱい（`Board::PSG_SPEAKER_PAN`）にしている。
  音源（`PSG::Synth`）は設定を「送り主 × チャンネル」ごとに覚えるので、`synth.handle` で直接送った設定は
  `Speaker`（送り主 `:mml`）の音には効かない。3 声を v15 で重ねると出力は電源いっぱいまで振れる
- **r1 の GROVE はピン順が逆**（Grove ケーブルをそのまま挿すと VCC と GND が入れ替わる）。**r1 と PV1 / V1 を GROVE でつながない**（2026-10-25 に一度やった。V1 の GPIO29 が r1 の GND に、GPIO28 が r1 の 3.3V に当たる）。PV1 で J4・J5 とも並びを入れ替えて直り、
  量産版 V1 も同じ。**PV1 / V1 はふつうの Grove ケーブルで挿せる**（黄・白・赤・黒 = J4 は SCL(GPIO7)・SDA(GPIO6)・5V・GND、
  J5 は GPIO29・GPIO28・3V3・GND）
- **GROVE の電源（赤）は 0Ω で選ぶ。量産版の部品表では J4（GROVE1）が 5V（R27）、J5（GROVE2）が 3V3（R25）**。
  R26（J4 を 3V3）と R16（J5 を 5V）は未実装。赤を GPIO に直接つながない

## 既知の落とし穴

実際に時間を溶かしたもの。同じ穴を掘り直さないこと。

### ビルド / テスト

- **`build/host` をホストとコンテナで共有している。** ホストで `rake` を起動すると
  `output here was built by another configuration, rebuilding it` が 1 行出るが、
  オブジェクトは消えない（前後で 90 個のまま）。ただし**無害ではない**: ホストで
  `rake sim:test` を走らせた直後のコンテナビルドが
  `Errno::ENOENT ... build/host/src/version.pi` で落ちた。`rm -rf build/host` で直る。
  **`rake docker:*` の背景実行では `rake aborted!` を必ず grep すること**——
  ログ末尾の `Artifacts copied` が無いのに古い ELF を焼いた
- **`picoruby-i2c` は posix ポートを持たない。** `spec.add_dependency 'picoruby-i2c'`
  を書くとホストテストのリンクが `I2C_write_timeout_us` 未定義で落ちる。
  ホストでテストする gem では宣言しないこと（`picoruby-adc` が `picoruby-gpio` で同じ判断）
- **`docs/testing-guide.md` の `test/mock/` は現在効かない。**
  `Picotest::Runner#run_test` はテストファイル 1 本しかターゲット VM へ埋め込まない。
  スタブは**テストファイル内に置く**
- コンテナはホストの uid/gid で動く。root 所有ファイルが出てきたら
  `docker compose run --rm --entrypoint chown shell -R 1000:1000 /work/...` で戻せる（sudo 不要）

### PicoRuby.wasm

- **`<script type="text/ruby">` は 1 つずつ別タスク**（`picorb_create_task`）になり、
  協調スケジューリングなので**実行順が保証されない**。依存があるなら 1 つに束ねる
- **JS ブリッジの引数は String / Integer / Float / nil / bool / JS::Object のみ。**
  Array や Hash を渡すと `TypeError`。interop ドキュメントの型対応表は `[]=` の話。
  `JS::Bridge.to_js` は使えるが要素ごとに push するので呼び出し回数が増える
- ブリッジは文字列を C 文字列として扱うので、**NUL を含むバイト列は途中で切れる**
- **`Base16.decode16` は 0 のバイトを捨てる**（1 バイトずつ `mrb_str_cat_cstr` で足すので、0 は何も足さない）。16 進で受けたバイト列は
  `SimApp.bytes_of_hex` で戻す。2026-10-30 に `game.mrb` を `decode16` で戻して送ったら、0 の抜けた `.mrb` が `app.mrb` になり、
  実機が起動のたびに落ちて再起動をくり返した（起動中に `s` で `/etc/init.d/r2p2` を飛ばして戻せた）。先頭の `RITE0400` には 0 が無いので形式の確認も通り、
  CRC も壊れたもの同士で一致した。**バイナリを送ったら、届いたものを元と丸ごと比べる**（`lib-update-check.cjs` は偽の基板の `rawHex` と比べる）
- **存在しない JS 関数を呼んでも例外にならない。** console に
  `Method not found or not a function: ...` が出るだけなので、静かに失敗する
- **`JS.global.fetch` は `.then` ではなくブロックを取る。** Promise 一般は `.await` / `.then`
- **`addEventListener(..., sync: true)` の中では `await` できない**
  （`Cannot use asynchronous Task API during synchronous execution`）。
  autoplay ポリシー対応で同期リスナーが要るときは、await しない経路を選ぶ
- 例外は `rescue Exception` で捕まえる。**構文エラーは `ScriptError`** なので
  `rescue => e` では捕まらず、タスクが黙って死ぬ
- `require 'i2c'` のような組み込み gem 依存は、ブラウザや `bin/picoruby` では
  `LoadError` になる。`Kernel#require` を包んで握り潰す（picotest のランナーと同じ手）
- **`Machine` は wasm ビルドに無い**（`core` gembox 由来で、
  `build_config/picoruby-wasm.rb` は取り込んでいない）。`MIDIBASE::Router` などが
  `Machine.uptime_us` を呼ぶので、`performance.now()` で代替する
- 純 Ruby の gem（`picoruby-midibase` / `-mml` など）は**ソースを fetch して連結すれば
  stock パッケージで動く**。C 拡張（`psg` / `gpio` / `pwm` / `vram` / `shinonome`）は動かない
- **実機の USB シリアルをブラウザ（WebSerial）で使うときは、WSL から外しておく。**
  `usbipd attach` したままだと Windows のブラウザのポート一覧に出ない
- **`JS::WebSerial` の `binary_capture_*` / `capture_*` は、`start_terminal_read`（xterm へ流す読み取り）と
  組でしか動かない。** `on_receive` で受けるなら、フレームは自前で切り出す必要がある（ページは今は端末読みに統一した）

- **gem の初期化が 1 つ失敗すると、それより後ろの gem は全部初期化されない。しかも何も出ない。**
  `mrb_open()` は例外を抱えたままの VM を返し、`picorb_init` は NULL しか見ていない。wasm に入れた
  `picoruby-is31fl3729` は `require 'i2c'` で毎回こうなっている（ページはドライバのソースを自分で読むので困っていなかった）。
  後ろに足した gem の定数が「ビルドには入っているのに実行時に無い」ときはこれ。`build_config/picoruby-wasm.rb` では
  **`picoruby-is31fl3729` を最後に置く**
- **コードの欄の色付けは Prism**（`picoruby-syntax-highlight` の `SyntaxHighlight.tokenize`）。`rake sim:wasm` の wasm にだけ入っている。
  仕組みは [sim/README.md](sim/README.md) の「コードの色付け」

### Funicular（UI フレームワーク）

- stock パッケージに同梱（`build_config/picoruby-wasm.rb`）。追加ビルド不要
- **HTML タグ名はコンポーネントのメソッド名にできない**（`code` `audio` `select` など）
- `pre` は**タグ DSL に無い**。`tag("pre", ...)` を使う
- 子要素は**ブロックの戻り値ではなく副作用**で集まる（`ViewContext#capture`）。
  ヘルパーの中でタグを呼べば足りる。配列を組んで返す必要はない
- クラスメソッドからインスタンスを叩くなら `public :foo` が要る
- **速く変わるものは state に置かない。** canvas / テキストエリア / ログは `ref` で持つ
  （毎回 VDOM 差分が走る。テキストエリアを state にするとカーソルが飛ぶ）
- **`Task.new` のブロックは、書いた場所のオブジェクトを `self` として走らない。** インスタンス変数は読めず、自分のメソッドも
  呼べない（`NoMethodError` か、`@x` が nil で黙って何もしない）。`link = self` で渡して名前で呼ぶ。イベントリスナのブロックも同じ
- **`JS::WebSerial#close` は `on_receive` で読んでいるポートでは永久に戻らない**（読み取りループを止める仕組みが端末用の
  `start_terminal_read` にしか無い）。ページは `start_terminal_read`（xterm.js に直接流す）で読むので今は問題ない。
  `on_receive` で読むなら、待たない `JS::WebSerial._close_port(raw)` を使う
- **実機の端末（xterm.js）と転送の作りは [sim/README.md](sim/README.md) の「実機で実行」。** プロンプト待ちは `capture_peek`、
  PicoModem は `binary_capture_read`（オンのあいだ端末には流れない）。転送のあと基板が出す `[PicoModem] write` とプロンプトは
  バイナリ側に先に入っていることがあるので、`$> ` までバイナリ側で読み切ってから端末に書く（切り替えの隙間で落ちる）
- **`JS::Object` 同士の `==` は同じ JS オブジェクトでも偽になる**（参照 ID の比較で、Ruby 側から見るたびに新しい ID が付く）。
  見分けたければ JS オブジェクトにプロパティで印を付ける
- **WebSerial の再接続は `tools/browser-check/reconnect-check.cjs`**（偽の `navigator.serial`）で実機なしに確かめられる。
  ［ライブラリを最新にする］と［ライブラリを初期設定に戻す］は `lib-update-check.cjs`（同じ偽の基板に `FILE_READ`・`mv`・`rm` を足した）
- **R2P2 の行エディタは、1 文字ごとに端末へカーソル位置を尋ね（`ESC [6n`）、返事を 0.5 秒まで待つ。その前に、まだ読んでいない入力を捨てる**
  （`IO.get_cursor_position`）。ページがやり取りの最中にキーを止めていたら返事まで止まり、1 文字 0.5 秒かかった。長い行を一度に送ると 32 バイトから先が捨てられた（V1、2026-10-28）。
  小分けにして表示を待っても、USB で 2 回に分かれて届いた後ろ半分が捨てられた。**ページからシェルに長い行を打たない。** ファイル操作は
  Ruby のスクリプトにして PicoModem で送り、短いパスだけを 1 回で送って実行する（`DeviceLink#file_ops`）。やり取りの最中もカーソル位置の返事だけは
  通す（`DeviceLink#type`）。効いたかはエラーの文字ではなく、ファイルを読み直して確かめる。手で打つ分には、1 文字ずつ間を空けて届くので落ちない。
  **バイナリの取り込みで受けた出力を端末に書くときは `ESC [6n` を抜く。** 基板はもう待っておらず、xterm の返事が次の転送の中に入って
  転送を終わらせた（`[PicoModem] timeout`）
- **基板の `File.rename` は既にあるファイルに上書きしない**（`File exists: … Can't overwrite` と出して戻るだけで、例外にならない）。シェルの `mv` も同じ
- **基板が PicoModem の ERROR を返したら、ページから ABORT を送らない。** 基板の転送モードはもう終わっていて、ABORT は STX で始まるので
  入り直させてしまう。転送に失敗したあとのプロンプトはバイナリの取り込みの中に消えていることがあるので、待たずに Ctrl-C で出させる
- **ハートビートで「前回表示した文字列」と比べるなら、`<<` で伸ばした文字列を渡さない。**
  覚えておいた値も同じオブジェクトなので一緒に伸び、いつ比べても等しくなって表示が止まる。
  `@log = @log + out` のように新しい文字列を作る
- **属性に `nil` を渡すと、最初の描画では `hidden=""` のように空文字で書かれる**（`setAttribute(key, nil.to_s)`。
  `disabled` など Funicular 自身の真偽属性の一覧にあるものだけ外される）。更新時は外れるので、
  「最初から出ているはずの要素が隠れている」ときはこれ。出し分けは `if` でタグごと切り替える
- **`patch` は、別の `patch` の描き直しの途中に来ると黙って捨てられる**（`return if @updating`）。クリックの処理は
  それぞれ別のタスクで走り、描き直しが重いと途中で切り替わる。ブレッドボードの穴を 190 個の要素で描いたら、
  部品を選んだ直後のクリックが古い部品のまま、あるいは丸ごと消えた。すぐ読み返す値は state ではなくインスタンス変数に置き、
  描き直しの依頼が捨てられたらハートビートで出し直す（`BoardView#refresh`）。要素の数も減らす（穴はクリック位置から計算）
- **要素の並びがずれると、Funicular はその後ろの要素を作り直す**（位置で対応を取るため）。数が変わるもの
  （ブレッドボードのスイッチ）の後ろに LED マトリクスの canvas があり、スイッチを挿すと canvas が新しくなって、
  掴んだままの古い canvas に描き続けて何も映らなくなった。数の変わるものは入れ物の div に入れ、JS 側は
  `isConnected` を見て掴み直す
- **`patch` はコンポーネントで定義し直せない**（`DSLCollisionError`）。中を見たいときは呼ぶ側に `puts` を置く
- **Funicular がマウントする要素を、スクリプト読み込み時に掴んではいけない。**
  まだ存在しない。遅延取得する

### wasm の自前ビルド

- **emsdk はホストと同じパスにマウントする。** 場所が変わると emscripten が
  キャッシュを丸ごと捨てる（`config changed, clearing cache`）
- **compose の `${VAR:?}` は使わない。** ファイル全体が検証されるので、
  1 サービスのための必須変数が**全コマンド**を壊す
- `brotli` がビルドの最後に要る（イメージに追加済み）
- `mrbgems/picoruby-wasm/npm/` の成果物は全部 gitignore 済み。戻す必要はない
- **`python3 -m http.server` は `Cache-Control` を返さないので、ブラウザは `picoruby.wasm` / `picoruby.js` を自分の判断で
  持ち続ける。** `rake sim:wasm` のあと再読み込みしても古い wasm で動いた（色付けが出なかった）。`index.html` が読み込み前に
  `cache: 'no-cache'` で確認しに行くようにしてある。**ヘッドレスの `sim:check` は毎回まっさらなので、この種の問題は見つけられない**
- 静的サーバは `.wasm` に `application/wasm` を返すこと。
  でないとストリーミングコンパイルが拒否される

### シミュレータのコードは実機と同じでなければならない

**シミュレータ専用の構文は全面的に禁止。** サンプルがそのまま基板に載らなくなり、
シミュレータの存在意義が消える。`every(ms) { }` と、`sim/` にだけあった
`matrix` / `buttons` / `speaker` / `board` / `panel` で 2 度指摘を受けた。

- サンプルが呼べるものは**すべて `lib/adventure_board.rb`**（ボードレイヤ）に置く
- `sim/` に置いてよいのは、実 gem と**同じ API を持つハードの代役**だけ
  （`I2C` / `GPIO` / `IRQ` / 仮想チップ）
- ループは実機と同じ `while true` + `sleep_ms`
  （`sleep_ms` はタスクを suspend してブラウザにイベントループを返すので固まらない）
- ペリフェラルの生成だけは両者で本当に違うので、**サンプルの外**で行う
  （実機は `Board.boot` の既定値、シミュレータは `sim_app.rb` が `$board` を用意）
- サンプルは `require 'adventure_board'` の 1 行と `GC.start` のあと、`matrix = AdventureBoard.matrix` と**変数に取り出して**使う。
  部品のファイル（`adventure_board/led_matrix` など）は `AdventureBoard.matrix` が初めて呼ばれたときに読まれる
  （`AdventureBoard.use`。読んだら `GC.start`）。実機では `/lib` から読み、ブラウザでは全部読み込み済みなので読まない
- **部品のファイルの中から `require 'adventure_board'` しない**（2026-09-27 に一度やって戻した）。入れ子の `require` は
  外のファイルを持ったまま中のファイルをコンパイルするので、r1 で連続空きが約 25KB → 7〜20KB になり、リセット直後の
  `kanji.rb` や、そのあとの `melody.rb` が 2〜3 回に 1 回 `NoMemoryError` になった。入れ子の直後の `GC.start` はもっと悪い
- **トップレベルの `matrix` / `buttons` / `speaker` / `board` はやめた**（2026-09-27）。変数に見えて代入元が無く、
  サンプルの `board = []`（life.rb）が黙って隠していた。`def` の中からはローカル変数が見えないので、
  `def` で使うなら引数で渡すか、中で `AdventureBoard.matrix` を取り出す

**サンプルのコメントの書き方**（`sim/examples/` と `examples/` で共通。2026-09-22 に全部そろえた）:

- **`sim/examples/` は一般ユーザのためのもの。基板の検証用のコードは置かない**（`dev-docs/device-bringup/scripts/` へ）。
  数を増やしすぎない。ページの選択肢は「初めての人が読む順」に並べる（`SimApp::EXAMPLES`）。
- **チュートリアルのコードは `sim/examples/` の番号付きのもの（`01_light.rb` など。番号は章）が正本**（2026-10-25）。
  サイトの本文は `<<< @/../sim/examples/…` で同じファイルを読むので、直せば両方が変わる。チュートリアルに無いサンプルは番号を付けない
- 「ローカルの wasm が要る」という断り書きは付けない（自前の wasm をいずれ一般公開する前提）
- 冒頭は**題名 1 行 + 多くても 2 行**（操作方法、必要なもの）。仕組みや経緯の説明は書かない（README か dev-docs に置く）
- 説明は**その行の横**に短く書く。初めて出てくる API に 1 回だけ。同じ説明を繰り返さない
- 先頭は全サンプル同じ形: `require 'adventure_board'` / `GC.start  # 読み込みで使ったメモリを回収する` / 空行 /
  `matrix = AdventureBoard.matrix  # LED マトリクス。使う部品は、こうして読み込んで取り出す` / `buttons = AdventureBoard.buttons  # ボタン` …
  （部品の名前は取り出す行の横に。説明は最初の 1 行にだけ）。
  **チュートリアルの番号付きのサンプルは、この先頭の行にコメントを付けない**（2026-10-25。本文のチュートリアル 1 が説明する）
- コメントを直すときはコードを触らない。コメントを除いた行が元と一致することを確かめる
- ブレッドボードを使うサンプルは、冒頭のあとに `# 配線:` の段落を置き、1 行 1 部品で `#   led c7 c9   説明` と書く
  （`Breadboard.wiring_in` が読み、ページが読み込み時にその配線にする。実物の手順書も兼ねる）

**ユーザのコードはトップレベルのメソッド（`run_user_source`）の中で `eval` する。** `SimApp` の中で `eval` すると、
ユーザの書いた `def` が `SimApp` に定義されて呼べず、**シミュレータでだけ** `NoMethodError` になった（実機では普通に動く構文）。
`sound_and_light.rb` がトップレベルの `def` を使っているので、`rake sim:check` がこの退行を拾う。

ユーザのコードは `Task` で走らせ、Run のたびに前を `terminate` する。
canvas はハートビートで仮想チップを映すので、コード側から再描画を指示しない。

### ボタン / 割り込み

- **ボタンはポーリングしない。** `picoruby-irq` のエッジ割り込みで受ける
  （`peripherals` gembox に含まれる。デバウンスは gem 内蔵）。
  ポーリングだと、短いクリックがサンプルの隙間に収まって**一度も観測されない**
- 押下はキューに積んで `take_press` / `each_press` で取り出す。
  ループの速さに関係なく 1 回の押しが 1 回として届く
- オートリピートは `Buttons` に入れずループ側で作る
- **シェルで流したスクリプトの GPIO 割り込みは、終わっても登録が残る。** 同じピンは
  新しい登録で置き換わるように直したが、**別のピンの登録は溜まる**（最大 16 個）。
  いろいろなピンを使うスクリプトを続けて流すときは、あいだに `tools/r2p2dev.py reset` を挟む
- `picoruby-irq` のデバウンスは作り直した（元は離すときのチャタリングが押下として届いた）。
  どちらも upstream の問題として [dev-docs/upstream-issues.md](dev-docs/upstream-issues.md) に記録
- **ボタンの代わりに GPIO を自分で動かして割り込みを試せる。** 出力にしたピンでも入力バッファが
  生きているので、同じピンの割り込みが立つ。空きは GPIO15、緑 LED の GPIO16 も使える

### 実機（Pico 2 W）

痛い目を見た順。詳細は [dev-docs/device-bringup/](dev-docs/device-bringup/)。

- **`require` 1 回の固定費が約 28KB**で、GC を呼ばないと返ってこない。
  コンパイルにはソースの約 6 倍の**連続**領域が要り、常駐は約 5 倍。
  **サンプルは使うペリフェラルを自分で require する**
  （`require 'adventure_board/led_matrix'`）。隠さないこと——
  何を読み込んでいるかはサンプルが教えることの一部で、実費でもある。
  `Board` 側は構築だけ遅延させる（使わないハードを起こさない）
- **終わった `Task` は `close` するまでメモリに残る**（1 つ約 1.3KB。GC では回収されない作り）。`MML::Player#start` は曲ごとに Task を作って
  `close` しないので、`play_mml` をくり返すといずれ `NoMemoryError`。量産基板のファームはもう直せないので、`/lib` の `Speaker` が前の曲の Task を `close` するようにした
  （[dev-docs/device-bringup/task-memory.md](dev-docs/device-bringup/task-memory.md)）
- **main の `lib/` は量産基板のファーム（`v2026.10.25`）で動くものに限る**（2026-10-27）。コンソールの［ライブラリを最新にする］が
  古いファームの基板に新しい `lib/` を書くため。ファームに無い C の gem・メソッドを `lib/` から使わない
  （[dev-docs/webserial-console/file-transfer-plan.md](dev-docs/webserial-console/file-transfer-plan.md)）
- **`lib/` を直したら `AdventureBoard::VERSION`（`lib/adventure_board.rb`、`YYYY.MM.DD`）の日付を上げる**（2026-10-28）。コンソールが
  「2026.10.25 版から 2026.10.28 版にしました」のように出す。最初のファーム（`v2026.10.25`）のライブラリには `VERSION` が無く、それを 2026.10.25 版と見なす。
  上げ忘れても書き換えは中身を比べて行うので壊れないが、表示がずれる。`rake sim:lib_files` は形だけ調べる
- **サンプルの時間は `sleep_ms` の回数ではなく時計（`Machine.uptime_us`）で決める。** 1 コマの描画時間がビルド
  （debug / prod）とシミュレータで数倍違うので、回数で作った曲はビルドを変えると速さが変わる（`sound_and_light.rb` で実際に起きた）
- **サンプルは require 1 本ごとに `GC.start` を呼ぶ。** `require.rb` は
  Sandbox を回収しないので、1 本 28KB が積み上がる。まとめて最後に呼んでも
  `max_free` は戻らない（12,328 のまま）。1 本ごとなら 20,736 まで増える
- **ボードライブラリは `lib/adventure_board.rb` + `lib/adventure_board/`**（2026-09-23 に `picorubykaigi01` から改名。
  基板の正式名称が Adventure Board になったため）。サンプルは `require 'adventure_board'` と `AdventureBoard.matrix`。古い名前のファームが入っていた基板では、
  新しいファームが最初の起動で `/lib/picorubykaigi01*` と古い印を消してから書き直す（`system_files.c` の `remove_old_library`）。
  **`/home/examples` は触らないので、古いサンプルは `require 'picorubykaigi01'` のまま壊れる**。r1 は `wipefs` して焼き直した
- **`devtest/` の仕組みは廃止した**（2026-09-23。ホストの `devtest/*.rb` をファームに焼き込んで `/home/devtest/` に書いていた）。
  スクリプトは `r2p2dev.py push` かページで送る。新しいファームは最初の起動で基板の `/home/devtest/` も消す
- **ファームは変わったファイルだけ書く。** `/etc/adventure-board-files` に
  中身のハッシュを置いて比べる。`/lib` は更新されるが、
  **`/home/examples` は、あるファイルには二度と触らない**（ユーザの編集物なので）。版が変わったとき、無いサンプルだけ足す。
  サンプルを直したら `tools/r2p2dev.py wipefs` で消してから焼く
- **openocd の `reset` を使わない。** SYSRESETREQ はペリフェラルを戻さないので、
  USB が半死のまま R2P2 が起動してプロンプトまで来ない。
  `r2p2dev.py reset` はウォッチドッグで落とす
- **prod は stdio が丸ごと無効**（`pico_enable_stdio_usb 0` / `_uart 0`）。
  `printf` はどこにも出ない
- **`r2p2dev.py` が出す `$> ...` はボードの応答ではない。** 出力が空＝ボードが無言
- **r1 基板では SWD の halt が効かない**（両コアが `unknown`）。メモリの読み書きと
  `program` は通る。ウォッチドッグ再起動は halt を `catch` で包んで書く
  （`flash.sh` / `r2p2dev.py` は対応済み）。書き込み後は UART に
  `installed /etc/adventure-board-files` が出るまで SWD を触らない
- **`r2p2dev.py reset` の直後に `run` しない。** ターゲットの起動中にプローブの
  UART へ送ると Debug Probe が USB ごと固まり、**抜き差しでしか戻らない**
  （usbipd の detach/attach では戻らない）。起動ログが流れ終わってから叩く
- **書き込みの直後に SWD でフラッシュを触らない。** 起動中のファームが
  `/lib` を書いている最中に消すと、書きかけが残って USB が死ぬ。
  `r2p2dev.py` の `reset` / `wipefs` はプロンプトが返るまで待つ
- 戻せなくなったら **BOOTSEL** → `tools/r2p2dev.py recover`
- **配布・リリースは prod ビルド**（2026-09-23 に決定。`R2P2_CONSOLE_UART=1 rake docker:r2p2:picoruby:pico2:prod` →
  `rake docker:flash:picoruby:pico2:prod`。r1 で起動・シェル・サンプルを確認済み）。debug は残してあり、調べたいときに
  `…:debug` を焼き直すだけ。prod では **C の `printf`（`[R2P2] installed …`、`PSG: PWM …` など）が一切出ない**ので、
  起動ログにそれが無くても異常ではない。`puts` は出る。ヒープは prod のほうが 12KB ほど広い
- **prod の速さ（r1 実測）**: `blit` 3.4ms（debug 17ms）、`show` 7.9ms（13ms）、`vram.draw_rect` 1 回 0.17ms（0.45ms）、
  音と光の 1 ステップ 11.6ms（31ms）。**起動後の最初の実行だけ数倍遅い**ことがある（2 回目から安定）
- **debug ビルドの Ruby は 1 メソッド呼び出しが約 100µs、`String#setbyte` 1 回が約 180µs**（r1、-O0 でフラッシュ上）。
  256 ドットを 1 つずつ Ruby で回すと 0.5 秒かかる。フレームごとの処理はドット単位のループにせず、
  ページ（`String`）単位で C に任せる（`frame=` / `reverse` / `draw_bitmap`）。`LedMatrix#blit` と `draw_text` で
  文字スクロールの 1 コマが 650ms → 40ms になった（debug）
- **debug ビルドは `-O0`、prod は `-O2`。** r1 は UART コンソールのために debug しか使わないので、
  時間に追われる処理（PSG の core1 など）は debug でだけ間に合わなくなる。締め切りのある関数には
  `__attribute__((optimize("O2")))` を付け、RAM に置く（`.time_critical`）。2 つのコアは同じフラッシュから
  命令を取るので、core0 が Ruby を回しているあいだ core1 のフラッシュ上のコードは 3 倍遅くなる
- **SDK の `static inline`（`dma_channel_is_busy` など）は `-O0` では関数として残り、フラッシュに置かれる。**
  RAM に置いた関数から呼ぶなら、レジスタを直接触る
- **SWD で変数を読み書きする番地は、ビルドのたびに `nm` で取り直す。** 古い番地にゼロを書いて基板を固めた。
  openocd で値を見るのは `echo "[read_memory ADDR 32 N]"`（`mdw` は `-c` では何も出さない）。halt は要らない
- **RP2350 の DMA `TRANS_COUNT` は上位 4 ビットが MODE。** RP2040 の例が書く
  `0xffffffff` は RP2350 では **ENDLESS**（カウントを減らさない）になり、
  バッファは埋まるのにカウンタが 0 のままになる。`0x0fffffff` を使う
- **PIO のピン方向はステートマシン間で共有される。** 受信側で pindirs を
  入力にすると、同じピンを使う送信側の出力が消える
- **埋まっているハードウェアアラームを `hardware_alarm_claim()` すると panic する。**
  0 は `picoruby-machine` のティック、1 と 2 は `picoruby-psg`、
  3 は SDK の既定アラームプール。`hardware_alarm_claim_unused()` で取る
- **GCC の "two or more data types in declaration specifiers" が健全な `bool` を
  指したら、手前の宣言が閉じていない。** 「未知の型」に見えるエラーも同じ。
  同じファイルの別の場所で同じ型が通っているなら、型の問題ではない
- **Ruby 側の無い gem でも `_gem_init` / `_gem_final` は要る**（リンクで落ちる）。
  `ports/rp2040/*.c` は CMake が自動で拾うので `CMakeLists.txt` は触らなくてよい

### その他

- `bin/picoruby` で相対パスを `load` するには `$LOAD_PATH = ["."]` が要る
- **トップレベル `def` は public**（CRuby は自動で private にするが mruby はしない）。
  `private` を**明示すれば**効く。`private` / `private :name` / `private def` /
  `protected` はいずれも呼び出しを止め、`send` は CRuby 同様に迂回できる。
  ただし `respond_to?` は可視性を見ず private でも true を返し、
  `Object.private_method_defined?` は存在しない
- ESM の `import` は `NODE_PATH` を見ない。`playwright install` は
  インストールしたユーザの HOME に置く（`PLAYWRIGHT_BROWSERS_PATH` で固定した）

## upstream との関係

このリポジトリは picoruby のフォークなので、**upstream のファイルへの変更は最小限に**。

**全部の一覧と理由は [dev-docs/upstream-changes.md](dev-docs/upstream-changes.md)。**
以下は要約:

- `Rakefile` — `tasks/docker.rake`・`tasks/sim.rake`・`tasks/site.rake` の load 3 行
- `build_config/r2p2-picoruby-pico2{,_w}.rb` — `conf.gem core:` 各 1〜2 行
  （`picoruby-is31fl3729` と `picoruby-pio-uart`）
- `build_config/r2p2-picoruby-pico2_w.rb` — `networking` / `picoruby-ble` /
  `picoruby-ble-uart` / `picoruby-keyboard` を**外した**。これで起動直後のヒープが
  290KB → 220KB になり、ボードライブラリが読めるようになる
  （[dev-docs/device-bringup/require-memory.md](dev-docs/device-bringup/require-memory.md)）
- `mrbgems/picoruby-r2p2/ports/rp2040/fault_handler.c` — フォールト時に
  ロックアップせず再起動する
- `mrbgems/picoruby-r2p2/ports/rp2040/main.c` / `cmake/CMakeLists.txt` — `/lib` と
  `/home/examples` を書き出す処理の呼び出しと生成ステップ
- `mrbgems/picoruby-uart/{include/uart.h,ports/rp2040/uart.c}` と
  `mrbgems/picoruby-irq/include/irq.h` — **`UART` に PIO のユニットを足した**
  （`UART.new(unit: :PIO_UART0, ...)`）。別クラスにしないのは、この基板で
  覚えたことが素の R2P2 で通じるようにするため
- `mrbgems/picoruby-machine/ports/rp2040/machine.c` — **`SLEEP_EN0/1` を絞る代入を消した。** 元は CPU が眠る
  （タスクが全部 `sleep_ms` などで待つ）たびに PWM / DMA / PIO / I2C / SPI / ADC が止まり、
  スピーカーの「ざらざら」の原因だった（[dev-docs/audio-quality/report.md](dev-docs/audio-quality/report.md)）
- `mrbgems/picoruby-littlefs/ports/rp2040/flash_hal.c` と `mrbgems/picoruby-psg/ports/rp2040/psg_port.c` —
  **フラッシュに書くあいだ core1（PSG）を待たせる。** 元は PSG を一度使ったあとにファイルを書くと core1 が固まった
- `mrbgems/picoruby-psg/` — キャリアを 132kHz に、DMA 2 チャンネルの交互連鎖、出力を中央基準に、三角波とエンベロープの修正。
  **core1 の音声処理は RAM に置き、debug ビルドでも `-O2`**（`PSG_HOT`）。元は各音のあたまにノイズが入った
- `mrbgems/picoruby-vram/` — 8bit 階調（`layout: :gray8`）
- `mrbgems/picoruby-irq/` — エッジのデバウンスを作り直し、同じピンの登録を置き換えにした（PR を送る前提。
  問題の記録は [dev-docs/upstream-issues.md](dev-docs/upstream-issues.md)）

新規ディレクトリ（`mrbgems/picoruby-is31fl3729/`、`mrbgems/picoruby-pio-uart/`、`mrbgems/picoruby-syntax-highlight/`、
`sim/`、`dev-docs/`、
`tools/`、`docker/`）は追加なので衝突しない。
`mrbgems/` **自体はサブモジュールではない**（サブモジュールは中の特定 gem だけ）。

⚠️ `tasks/picoruby/r2p2.rake` は `%w[pico pico_w pico2 pico2_w]` を決め打ちで
ループしてタスクを生成する。独自ボード名を足すにはここに手を入れる必要がある（未対応）。

## ドキュメント

| 場所 | 内容 |
|---|---|
| [dev-docs/](dev-docs/) | 計画とハード仕様の索引 |
| [dev-docs/board-gems/](dev-docs/board-gems/) | 基板の全機能を Ruby から触るための gem 棚卸し |
| [dev-docs/led-matrix-gem/](dev-docs/led-matrix-gem/) | LED ドライバの実装計画とハード仕様 |
| [dev-docs/wasm-simulator/](dev-docs/wasm-simulator/) | ブラウザシミュレータの計画と完了レポート |
| [dev-docs/device-bringup/](dev-docs/device-bringup/) | 実機で踏んだ穴。**Debug Probe だけで触る手順書**、WSL からの書き込み、`require` の費用 |
| [dev-docs/grove-link/](dev-docs/grove-link/) | 基板 2 枚を GROVE-B で繋ぐ。PIO で UART を作る |
| [docker/README.md](docker/README.md) | ビルド環境の詳細 |
| [sim/README.md](sim/README.md) | シミュレータの使い方 |
| [site/README.md](site/README.md) | 使い方とチュートリアルのサイト（VitePress）。`rake site:dev` / `site:build` / `site:preview` |
| [examples/](examples/) | **実機専用**サンプル（シミュレータに無いハードを使うもの） |

## 進捗

- ✅ Docker ビルド環境、`rake docker:*`、SWD 書き込み
- ✅ `mrbgems/picoruby-is31fl3729`（23 テスト / 60 アサーション）。r1 実チップで
  0x34 / 0x35 とも応答。LGC の落とし穴を見つけて吸収済み
- ✅ `mrbgems/picoruby-pio-uart`（PIO + DMA のエンジン。`UART` の `:PIO_UART0`
  ユニットとして見える。`gets` / `irq` まで実機ループバックで検証済み）
- ✅ ブラウザシミュレータ（LED / ボタン / 音声）と検証環境。UI は Funicular。コードの欄は Prism で色付け
- ✅ シミュレータの左を量産版 V1 の基板の絵（KiCad の 3D 描画）にし、ブレッドボードで回路を組めるようにした
  （ジャンパ線・抵抗 1kΩ・青 LED・タクトスイッチ。回路は節点解析で本当に解く。J1 の GPIO はコードから実機と同じに見える）。
  使い方は [sim/README.md](sim/README.md) の「基板の絵とブレッドボード」
- ✅ `lib/adventure_board.rb`（ボードレイヤ: Board / LedMatrix / Buttons / Speaker）
- ✅ フォント描画（`picoruby-shinonome`）と VRAM 描画 API。16×16 に漢字が出る
- ✅ `picoruby-vram` に 8bit 階調（`layout: :gray8`）。線も文字も明るさを持てる
- ✅ 明るさは見た目に比例（`LedMatrix#duty_of` でガンマ 2.0。テーブル無し、
  `set` の 1 箇所だけ。シミュレータは描画時に平方根で戻す）
- ✅ `/lib` への配布 — ファームが内蔵し初回起動時に書き出す（UF2 1本。実機未検証）
- ✅ Pico 2 W 実機で `require 'adventure_board'` → `/home/examples/status_led.rb` が動く
- ✅ ファーム更新で `/lib` を配り直す（中身のハッシュで判定。サンプルは触らない）
- ✅ GROVE-B の基板間リンク — **普通の `UART`**（`unit: :PIO_UART0`）。
  受信は DMA のリングバッファ。ストレートケーブルで繋がる。
  **2026-10-25 に量産版 V1 の 2 枚をふつうの Grove ケーブルでつなぎ、両方向に届くことを確認**（`dev-docs/device-bringup/scripts/grove_link_check.rb`）。
  同じ起動のあいだに役割を選び直すと最初のピンのまま動いていた件は直した（2026-10-25、`Board#grove_link` の使い回し・`PIO_UART_open` の `BUSY`・
  閉じるときの DMA の固まり（RP2350-E5）の 3 つ。V1 2 枚で役割を 3 回入れ替えて確認）。**ケーブルは赤（電源）の線を切った Grove ケーブル**（3.3V どうしがつながるため）
- ✅ スピーカーの音（PSG）。ざらざら・音程・三角波を直した。各音のあたまのノイズも直した（ADC の記録と耳で確認）。
  経緯と測定は [dev-docs/audio-quality/report.md](dev-docs/audio-quality/report.md)。基板自身の ADC で出力を録る
  `picoruby-adc-capture`（J6 → GPIO26）と `tools/adc_capture_dump.py` が検証に使える
- ✅ **2026-10-25 に一般公開した**（予定の 10-31 より前倒し）。**2026-10-26 から URL が変わった**:
  使い方とチュートリアル **https://picorubykaigi.org/adventure-board/**（リポジトリ `picorubykaigi/adventure-board` の Pages）、
  コンソール **https://picorubykaigi.org/adventure-board-console/**（`picorubykaigi/adventure-board-console` の Pages）。
  組み立て方はこのリポジトリの `.github/workflows/build-guide.yml` / `build-console.yml` にあり、2 つのリポジトリの `deploy.yml` がそれを呼ぶ。
  **ドキュメントやコンソールを直したら、2 つのリポジトリの deploy を手で起動しないと公開中のサイトは変わらない**
  （`gh workflow run deploy.yml -R picorubykaigi/adventure-board` と `-R picorubykaigi/adventure-board-console`）。
  古い https://picorubykaigi.org/adventure-board-firmware/ は、このリポジトリの Pages に `site/old-url-redirect/` を出して新しい URL へ送っている。
  コンソールは `window.REPO_ROOT`（`sim/index.html`）の下から `lib/` などを読む（単独版は `./repo/`）。詳しくは [site/README.md](site/README.md)。
  シミュレータのブレッドボードに番号（1〜17、a〜j）を付けた（実物には無い）
- ✅ ファームウェアの最初のリリース `v2026.10.25`（`56b9115d` の prod、`R2P2_CONSOLE_UART=1`。UF2 は `adventure-board-2026.10.25.uf2`）。
  最初は `a32d9d72` で出し、同じ日に GROVE リンクの修正を入れた `56b9115d` に差し替えた（タグも付け直した）。2026-10-26 に量産基板へ書き込む
- ⬜ GROVE-A センサ、サンプルプログラムの拡充
- ✅ r1 実基板に `pico2` debug ビルドを SWD で焼き、UART で起動ログを確認
- ✅ r1 で LED マトリクス（向き・列反転・階調）とスピーカー（`melody.rb`）が動く
- ✅ r1 でボタン 6 個とステータス LED（名前はシルク印字に合わせて修正済み）
- ✅ r1 の GROVE1（J4 = I2C1）に M5Stack CardKB（0x5F）を**逆ケーブル**で繋ぎ、
  キー入力が読めた
- ✅ r1 の GROVE2（J5）: 信号線 2 本をジャンパでつなぎ、導通（両方向）と
  PIO UART（TX=GPIO28 → RX=GPIO29、0〜255 の全バイト）を確認。
  ADC とピン順（同じ部品なので逆の可能性が高い）は未確認
- ✅ R2P2 コンソールを UART にも出す（`R2P2_CONSOLE_UART=1`。r1 は USB を手で直したが、Probe の UART からも同時に叩ける）。
  `R2P2_PORT=/dev/ttyACM0 tools/r2p2dev.py run ...` でプローブの UART から叩ける
- ✅ シミュレータのページから USB で実機に送って実行（[実機で実行]、WebSerial + PicoModem）。
  USB を直した基板で確認。何度も実行すると実機が応答しなくなる件は、PSG（core1）を止めずにフラッシュへ書いていたのが原因で、修正済み
  （[dev-docs/upstream-issues.md](dev-docs/upstream-issues.md) の 4）
- ✅ J1（ブレッドボード用 2×10 ヘッダ）の疎通確認（2026-09-26 に完了とした）。手順とスクリプトは
  [dev-docs/device-bringup/scripts/header_check.rb](dev-docs/device-bringup/scripts/header_check.rb)
- ✅ PV1 基板に prod を USB（UF2）で焼き、USB 接続（WebSerial）と音が r1 と同じく問題ないことを確認（2026-10-03）
- ✅ PV1 の GROVE1（J4）を I2C のデバイスで確認済み（2026-10-04 に記録。M5Stack のキーボードなど）
- ✅ PV1 の GROVE2（J5）をふつうの Grove ケーブル（ジャンパ変換）で確認（2026-10-04）。短絡なし、黄 = GPIO29・白 = GPIO28、
  電源 3.3V、黒 = GND、PIO UART で 0〜255 の折り返し。スクリプトは [dev-docs/device-bringup/scripts/grove2_check.rb](dev-docs/device-bringup/scripts/grove2_check.rb)
- ✅ 量産版 V1 が届いた（2026-10-19）。1 枚に prod（`66e32805`）を USB（UF2）で焼き、LED マトリクスとスピーカーが動くことを確認。
  ボタン・GROVE などは未確認（回路は PV1 と同じ）
- ⬜ 基板用 build_config（`tasks/picoruby/r2p2.rake` の
  ボード名ループに手を入れる必要がある）
