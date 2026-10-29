# The simulator's UI, as a Funicular component.
#
# Funicular is PicoRuby.wasm's VDOM framework and ships in the stock package, so
# the whole page is Ruby. Three things stay outside it and are reached through
# refs: the canvas, the code box and the note log. That is the framework's own
# pattern (demo/www/webaudio.rb draws its scope the same way) and it is there
# for a reason — all three change far too often to be worth a VDOM diff, and a
# textarea whose value lives in state loses the caret on every keystroke.
#
# Careful with method names: every HTML tag is a reserved word on a Component,
# so `code`, `audio`, `select` and friends cannot be used here.
require 'js'
require 'syntax-highlight'   # only in the wasm from `rake sim:wasm`; the stock one goes without colours

# Bringing the board up is the one thing that genuinely differs between here
# and the device, so it is the one thing done here: the peripherals are
# stand-ins and the audio sink can be switched on later. Everything a program
# touches — `board`, `matrix`, `buttons`, `speaker` — comes from the board
# layer and is identical on the device.
$panel = Panel.new
$notelog = NoteLog.new
$audio_sink = SwitchableSink.new
$board = Board.boot(i2c: $panel.i2c, speaker_backend: $audio_sink)
$board.speaker.router.connect(:mml, $notelog)
$app = nil
# The real board over USB. Page machinery like the note log: a sample never
# sees it, it only carries the sample to the board.
$device = nil   # made once the page is up: it needs the terminal's box (SimApp#component_mounted)


# Where the code typed into the page is evaluated. A method at the top level
# on purpose: a `def` in the user's code is then defined where a script's own
# top-level `def` would be on the board, on Object, and can be called from the
# rest of that code. Evaluated inside SimApp it landed on SimApp instead, and
# `draw_bar(...)` two lines later was a NoMethodError -- on the simulator only.
def run_user_source(source)
  eval(source)
end

# Turns a program into HTML for the coloured copy of the code box: one
# <span class="kN"> per run of bytes that SyntaxHighlight gave the same
# category. Prism's tokens begin and end on character boundaries, so cutting
# the source at those bytes never splits a character.
module CodeColors
  def self.html(source)
    kinds = SyntaxHighlight.tokenize(source)
    return escape(source) if kinds.nil? || kinds.bytesize != source.bytesize
    out = ""
    size = source.bytesize
    start = 0
    while start < size
      kind = kinds.getbyte(start)
      stop = start + 1
      while stop < size && kinds.getbyte(stop) == kind
        stop += 1
      end
      text = escape(source.byteslice(start, stop - start).to_s)
      if kind == 0
        out << text
      else
        out << "<span class=\"k#{kind}\">" << text << "</span>"
      end
      start = stop
    end
    # A <pre> gives no height to a line break at its very end; the textarea
    # does, and the two have to stay the same height to scroll together.
    out << " " if source.end_with?("\n")
    out
  end

  def self.escape(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end

class SimApp < Funicular::Component
  include BoardView

  # The tutorial's, in its order (the number is the chapter), then the rest.
  EXAMPLES = [
    ["1. 1 ドット光らせる", "01_light.rb"],
    ["1. 場所と明るさを変える", "01_light_more.rb"],
    ["2. 点を動かす", "02_loop.rb"],
    ["2. 跳ねるボール", "02_bounce.rb"],
    ["3. 線と四角を描く", "03_draw.rb"],
    ["3. 漢字を出す", "03_kanji.rb"],
    ["3. 文字を流す", "03_scroll.rb"],
    ["4. ボタンで動かす", "04_buttons.rb"],
    ["4. 押しているあいだ", "04_buttons_held.rb"],
    ["5. メロディを鳴らす", "05_melody.rb"],
    ["5. ボタンのピアノ", "05_piano.rb"],
    ["6. 石よけゲーム", "06_game.rb"],
    ["7. ブレッドボードの LED", "07_breadboard_led.rb"],
    ["3 声のメロディ", "harmony.rb"],
    ["音と光", "sound_and_light.rb"],
    ["ステータス LED", "status_led.rb"],
    ["ライフゲーム", "life.rb"]
  ]

  # examples/: the ones for hardware the simulator does not have. Listed so
  # that they can be read, edited and sent to a board with 実機で実行; Run
  # here says so instead of failing on a missing class.
  DEVICE_EXAMPLES = [
    ["OLED に文字とボール", "oled.rb"],
    ["音のエンベロープ", "envelope.rb"],
    ["基板 2 枚をつなぐ", "grove_link_chat.rb"]
  ]
  DEVICE_ONLY = "実機専用のサンプルです（シミュレータには無いハードを使います）。基板をつないで「実機で実行」で送ってください。"

  # The board library, as it is in the board's /lib: what "ライブラリを最新にする"
  # writes there, and what the library view shows. The page itself runs all of
  # it but grove_link.rb (index.html), since the simulator has no UART.
  # `rake sim:lib_files` checks this against lib/.
  # What the first firmware (v2026.10.25) wrote to /lib: a library with no
  # AdventureBoard::VERSION is that one.
  FIRST_LIB_VERSION = "2026.10.25"

  LIB_FILES = [
    "adventure_board.rb",
    "adventure_board/board.rb",
    "adventure_board/led_matrix.rb",
    "adventure_board/buttons.rb",
    "adventure_board/speaker.rb",
    "adventure_board/status_led.rb",
    "adventure_board/grove_link.rb"
  ]

  KEY_PINS = {
    "ArrowUp" => 17, "ArrowLeft" => 18, "ArrowRight" => 19, "ArrowDown" => 20,
    "z" => 22, "Z" => 22, "x" => 21, "X" => 21
  }

  MONITOR_MS = 50

  # --- the run loop, which outlives any one render -------------------------

  # The code typed into the page runs in a task of its own, so it can be
  # written exactly as it would be on the board — `while true` with `sleep_ms`,
  # which suspends the task and hands the browser back its event loop. Nothing
  # here is a simulator-only construct; a sample that runs on this page runs on
  # the device unchanged.
  def self.stop_task
    task = $user_task
    $user_task = nil
    return nil unless task
    begin
      task.terminate
    rescue Exception
      nil # already finished
    end
    nil
  end

  def self.start_task(source)
    stop_task
    $user_task = Task.new(name: "sim-user") do
      begin
        run_user_source(source)
      rescue Exception => e
        $app.report("実行エラー", e) if $app
      end
    end
    nil
  end

  # --- state ---------------------------------------------------------------

  def initialize_state
    {
      status: "準備しています…",
      kind: "busy",
      gcc: 32,
      notes_visible: false,
      held: [],
      device: :none,
      device_supported: DeviceLink.supported?,
      # Bumped to render the board picture again; what it shows is kept in
      # BoardView's instance variables.
      bb_version: 0
    }
  end

  def component_mounted
    $app = self
    load_breadboard
    wire_device
    wire_keyboard
    start_monitor
    draw
    patch(status: "準備できました。", kind: "ok")
    load_example(initial_example)
    nil
  end

  # A re-render can hand back a fresh canvas, which would be blank.
  def component_updated
    @parts_shown = nil
    draw
    nil
  end

  # --- render --------------------------------------------------------------

  def render
    div(class: "wrap") do
      div(class: "panel-side") do
        board_view
        div(class: "controls") do
          label(for: "gcc") { "明るさ (GCC)" }
          input(type: "range", id: "gcc", min: "0", max: "64",
                value: state[:gcc].to_s, oninput: :on_gcc)
          span { state[:gcc].to_s }
        end
        div(class: "legend") do
          span { "ボタンは絵の上で押すか、キーボードで（矢印キー / Z=A / X=B）" }
          br
          span { "LED マトリクスやブレッドボードをクリックすると拡大されます" }
        end
      end

      div(class: "code-side") do
        # Two boxes, so that it is plain which buttons act on the picture on
        # the left and which on a board at the end of a cable -- "Reset" on
        # its own could have been either.
        div(class: "group") do
          span(class: "group-title") { "シミュレータ" }
          div(class: "controls") do
            select(id: "examples", onchange: :on_example) { example_options }
            button(id: "run", class: "primary", onclick: :on_run) { "Run" }
            button(id: "reset", onclick: :on_reset) { "シミュレータをリセット" }
          end
        end
        div(class: "group") do
          span(class: "group-title") { "実機（USBシリアル接続）" }
          div(class: "controls") { device_controls }
        end
        # The code and the board's terminal, side by side where there is room
        # (index.html's .work). The text size is picked in the page's top bar.
        div(class: "work") do
          div(class: "code-pane") do
            div(class: "pane-title") { "コード" }
            div(class: "editor") do
              tag("pre", id: "code-colors") { "" }
              textarea(ref: :codebox, id: "code", spellcheck: "false")
            end
            div(id: "status", class: state[:kind]) { state[:status] }
          end
          # The board's shell. There from the start (xterm.js has to open into
          # a box that has a size) wherever the browser can do WebSerial.
          # Not `hidden: nil`: on the first render Funicular writes a nil
          # attribute as hidden="" (only its own list of boolean attributes is
          # treated as such), and the box would start out hidden.
          if state[:device_supported]
            div(class: "term-pane") do
              div(class: "pane-title") { "実機端末(xterm)" }
              div(id: "devicelog")
            end
          end
        end
        # Read-only: the library a program calls into. Shown on request, and
        # kept in instance variables like the board picture's (BoardView).
        # In a box of its own, so that opening it does not shift the note
        # log below: Funicular matches elements by position and would build
        # the log anew, empty.
        div(id: "lib-view") do
          button(id: "lib-toggle", class: "disclosure", onclick: :on_lib_toggle) do
            @lib_visible ? "▾ ライブラリのコード（lib/）" : "▸ ライブラリのコードを見る"
          end
          if @lib_visible
            div(class: "controls") do
              select(id: "lib-files", onchange: :on_lib_file) { lib_options }
            end
            tag("pre", ref: :lib_code, id: "lib-code") { "" }
          end
        end
        # Kept in the document even when hidden: it is how a melody can be
        # checked without hearing it, and the browser harness reads it.
        # At the very bottom, as a line of text rather than a button: up in
        # the row with Run it was in the way of the buttons that get pressed
        # all the time.
        button(id: "notes-toggle", class: "disclosure", onclick: :on_notes_toggle) do
          state[:notes_visible] ? "▾ 鳴った音" : "▸ 鳴った音を見る"
        end
        # `pre` is not one of the DSL's tags, so it goes through the generic
        # helper.
        tag("pre", ref: :notes, id: "notelog",
            hidden: state[:notes_visible] ? nil : "hidden")
        # For when a board's library is in a state the buttons above cannot
        # mend. Last on the page, closed: not something to press by chance.
        if state[:device_supported]
          div(id: "device-advanced") do
            button(id: "advanced-toggle", class: "disclosure", onclick: :on_advanced_toggle) do
              @advanced_visible ? "▾ 高度な機能（実機用）" : "▸ 高度な機能（実機用）"
            end
            if @advanced_visible
              div(class: "controls") do
                button(id: "device-run-mrb", onclick: :on_device_run_mrb,
                       disabled: (state[:device] == :connected) ? nil : "disabled") do
                  ".mrb にして実機で実行"
                end
                button(id: "device-install-mrb", onclick: :on_device_install_mrb,
                       disabled: (state[:device] == :connected) ? nil : "disabled") do
                  "実機の app.mrb にする"
                end
              end
              div(class: "legend") do
                "［.mrb にして実機で実行］コードの欄のプログラムを、このページでコンパイルしてから送って動かします（#{DeviceLink::RUN_MRB_PATH}）。" \
                "実機の上でコンパイルしないので、大きいプログラムでもメモリが足りなくなりにくくなります。"
              end
              div(class: "legend") do
                "［実機の app.mrb にする］同じものを #{DeviceLink::APP_MRB_PATH} に書き、電源を入れるたびに動くようにします。" \
                "app.mrb があると app.rb は動きません。［実機の app.rb にする］と［実機の app.rb を空にする］は app.mrb を消します。"
              end
              div(class: "controls") do
                button(id: "device-update-lib", onclick: :on_device_update_lib,
                       disabled: (state[:device] == :connected) ? nil : "disabled") do
                  "ライブラリを最新にする"
                end
                button(id: "device-reset-lib", onclick: :on_device_reset_lib,
                       disabled: (state[:device] == :connected) ? nil : "disabled") do
                  "ライブラリを初期設定に戻す"
                end
              end
              div(class: "legend") do
                "［ライブラリを最新にする］実機の /lib を、最新のライブラリ（#{lib_version} 版）に書き換えて再起動します。"
              end
              div(class: "legend") do
                "［ライブラリを初期設定に戻す］実機の /lib を、実機のファームウェアに入っている版（量産基板なら #{FIRST_LIB_VERSION} 版）に戻して再起動します。"
              end
              div(class: "legend") do
                "どちらも /home 以下のファイルは影響を受けません。"
              end
            end
          end
        end
      end
    end
  end

  private

  # These add their elements to whatever block is being captured, so nothing
  # needs to be collected or returned.
  def device_controls
    unless state[:device_supported]
      span(class: "legend") { "実機への接続は Chrome / Edge でだけ使えます" }
      return nil
    end
    connected = state[:device] != :none
    busy = state[:device] == :busy
    button(id: "device-connect", onclick: :on_device_connect,
           disabled: busy ? "disabled" : nil) do
      connected ? "実機を切断" : "実機に接続"
    end
    button(id: "device-run", class: "primary", onclick: :on_device_run,
           disabled: (connected && !busy) ? nil : "disabled") do
      "実機で実行"
    end
    button(id: "device-reboot", onclick: :on_device_reboot,
           disabled: (connected && !busy) ? nil : "disabled") do
      "実機を再起動"
    end
    button(id: "device-install", onclick: :on_device_install,
           disabled: (connected && !busy) ? nil : "disabled") do
      "実機の app.rb にする"
    end
    button(id: "device-clear", onclick: :on_device_clear,
           disabled: (connected && !busy) ? nil : "disabled") do
      "実機の app.rb を空にする"
    end
    nil
  end

  # The library this page carries (and runs in the simulator).
  def lib_version
    AdventureBoard::VERSION
  rescue Exception
    "?"
  end

  def lib_options
    list = LIB_FILES
    i = 0
    while i < list.size
      option(value: list[i], selected: list[i] == @lib_file ? "selected" : nil) { "lib/#{list[i]}" }
      i += 1
    end
    nil
  end

  def example_options
    # `optgroup` is not one of the DSL's tags either. The tutorial's names
    # start with the chapter's number.
    tag("optgroup", label: "チュートリアル") do
      list = EXAMPLES
      i = 0
      while i < list.size
        example_option(list[i][1], list[i][0]) if "0123456789".include?(list[i][1][0])
        i += 1
      end
    end
    tag("optgroup", label: "そのほか") do
      list = EXAMPLES
      i = 0
      while i < list.size
        example_option(list[i][1], list[i][0]) unless "0123456789".include?(list[i][1][0])
        i += 1
      end
    end
    tag("optgroup", label: "実機専用（シミュレータでは動かない）") do
      list = DEVICE_EXAMPLES
      i = 0
      while i < list.size
        example_option("device:#{list[i][1]}", list[i][0])
        i += 1
      end
    end
    nil
  end

  # selected: nil would still be written as selected="" on the first render,
  # so the attribute is left out instead.
  def example_option(value, label)
    if value == initial_example
      option(value: value, selected: "selected") { label }
    else
      option(value: value) { label }
    end
  end

  # What the page opens with: ?example=<a value of the list>, such as
  # ?example=device:oled.rb, or the first sample.
  def initial_example
    @initial_example ||= begin
      wanted = JS.global.queryParam("example").to_s
      example_values.include?(wanted) ? wanted : EXAMPLES[0][1]
    end
  end

  def example_values
    values = []
    i = 0
    while i < EXAMPLES.size
      values << EXAMPLES[i][1]
      i += 1
    end
    i = 0
    while i < DEVICE_EXAMPLES.size
      values << "device:#{DEVICE_EXAMPLES[i][1]}"
      i += 1
    end
    values
  end

  # --- handlers ------------------------------------------------------------

  def pin_of(event)
    target = event.target
    return nil unless target
    value = target.getAttribute('data-pin')
    return nil if value.nil?
    value.to_s.to_i
  end

  def on_press(event)
    pin = pin_of(event)
    hold(pin, true) if pin
    nil
  end

  def on_release(event)
    pin = pin_of(event)
    hold(pin, false) if pin
    nil
  end

  def hold(pin, down)
    if down
      GPIO.press(pin)
      held = state[:held]
      patch(held: held + [pin]) unless held.include?(pin)
    else
      GPIO.release(pin)
      held = state[:held]
      patch(held: held - [pin]) if held.include?(pin)
    end
    nil
  end

  def on_gcc(event)
    value = event.target[:value].to_s.to_i
    patch(gcc: value)
    AdventureBoard.matrix.brightness = value
    draw
    nil
  end

  def on_example(event)
    load_example(event.target[:value].to_s)
    nil
  end

  # Run is also what switches the sound on. A browser only lets a page make
  # sound from inside a click, and this is the click everyone makes anyway;
  # it used to take a button of its own, which was easy to forget, and then a
  # melody played in silence.
  def on_run(_event)
    enable_audio
    box = refs[:codebox]
    source = box ? box[:value].to_s : ""
    # A device-only sample as it was loaded would only fail here. Edited, it
    # is someone's own code, and runs.
    device = @device_example
    if device && device[:source] && device[:source] == source
      patch(status: DEVICE_ONLY, kind: "busy")
      return nil
    end
    run(source)
    nil
  end

  def on_reset(_event)
    begin
      SimApp.stop_task
      AdventureBoard.speaker.stop
      $notelog.clear
      GPIO.reset
      $panel = Panel.new
      $board = Board.boot(i2c: $panel.i2c, speaker_backend: $audio_sink,
                          global_current: state[:gcc])
      $board.speaker.router.connect(:mml, $notelog)
      patch(held: [], status: "リセットしました", kind: "ok")
      draw
    rescue Exception => e
      report("リセット", e)
    end
    nil
  end

  # Runs on the click itself: the browser only shows its port picker for a
  # user gesture.
  def on_device_connect(_event)
    begin
      if $device.connected?
        $device.disconnect
        patch(device: :none, status: "実機を切断しました", kind: "ok")
      else
        $device.connect
        patch(device: :connected, kind: "ok",
              status: "実機に接続しました。シェルの出力は下に出ます。")
      end
    rescue Exception => e
      patch(device: $device.connected? ? :connected : :none)
      report("実機への接続", e)
    end
    nil
  end

  # The transfer waits on the board many times over, so it runs in a task of
  # its own and reports back when it is done.
  def on_device_run(_event)
    box = refs[:codebox]
    source = box ? box[:value].to_s : ""
    patch(device: :busy, status: "実機に送っています…", kind: "busy")
    Task.new(name: "device-run") do
      begin
        $device.run(source)
        $app.device_finished(nil) if $app
      rescue Exception => e
        $app.device_finished(e) if $app
      end
    end
    nil
  end

  # The code becomes the board's own program: /home/app.rb, which R2P2 runs
  # at every start -- what a board does on its own, with no computer.
  def on_device_install(_event)
    box = refs[:codebox]
    source = box ? box[:value].to_s : ""
    patch(device: :busy, status: "実機の #{DeviceLink::APP_PATH} に書いています…", kind: "busy")
    Task.new(name: "device-install") do
      begin
        $device.install(source)
        $app.device_installed(nil) if $app
      rescue Exception => e
        $app.device_installed(e) if $app
      end
    end
    nil
  end

  def device_installed(error)
    patch(device: $device.connected? ? :connected : :none)
    if error
      report("実機の app.rb にする", error)
    else
      patch(kind: "ok", status: "#{DeviceLink::APP_PATH} に書いて実行しています。電源を入れるたびにこのプログラムが動きます。")
    end
    nil
  end

  # Back to a board that starts at its prompt.
  def on_device_clear(_event)
    patch(device: :busy, status: "実機の #{DeviceLink::APP_PATH} を空にしています…", kind: "busy")
    Task.new(name: "device-clear") do
      begin
        $device.clear_app
        $app.device_cleared(nil) if $app
      rescue Exception => e
        $app.device_cleared(e) if $app
      end
    end
    nil
  end

  def device_cleared(error)
    patch(device: $device.connected? ? :connected : :none)
    if error
      report("実機の app.rb を空にする", error)
    else
      patch(kind: "ok", status: "実機のプログラムを止めて、#{DeviceLink::APP_PATH} を何もしない 1 行にしました。" \
                                "電源を入れても何も走りません。")
    end
    nil
  end

  # Stops the program on the board and restarts it. The link drops while it
  # restarts and comes back by itself; draw_device reports both.
  def on_device_reboot(_event)
    patch(device: :busy, status: "実機を再起動しています…", kind: "busy")
    Task.new(name: "device-reboot") do
      begin
        $device.reboot
        $app.device_rebooting(nil) if $app
      rescue Exception => e
        $app.device_rebooting(e) if $app
      end
    end
    nil
  end

  def device_rebooting(error)
    if error
      patch(device: $device.connected? ? :connected : :none)
      report("実機の再起動", error)
    else
      # Still shown as connected until the port actually goes; draw_device
      # takes it from there.
      patch(device: $device.connected? ? :connected : :none, kind: "busy",
            status: "実機を再起動しました。起動し終わると自動でつなぎ直します。")
    end
    nil
  end

  # Writes this page's lib/ over the board's /lib, where they differ, and
  # restarts the board if anything changed. The page's copies are fetched
  # first, so a page that cannot read them leaves the board alone.
  def on_device_update_lib(_event)
    patch(device: :busy, status: "実機のライブラリとこのページのものを比べています…", kind: "busy")
    Task.new(name: "device-update-lib") do
      begin
        files = []
        i = 0
        while i < SimApp::LIB_FILES.size
          name = SimApp::LIB_FILES[i]
          text = nil
          status = nil
          JS.global.fetch("#{JS.global[:REPO_ROOT].to_s}lib/#{name}", { cache: "no-store" }) do |response|
            if response[:ok]
              text = response.text.await.to_s
            else
              status = response[:status].to_i
            end
          end
          raise "lib/#{name} を読めませんでした（#{status}）" if text.nil?
          files << ["/lib/#{name}", text]
          i += 1
        end
        result = $device.update_library(files)
        $app.device_updated_lib(result, nil) if $app
      rescue Exception => e
        $app.device_updated_lib(nil, e) if $app
      end
    end
    nil
  end

  # The code compiled here, the way the board would (the same compiler and
  # the same build settings: dev-docs/webserial-console/file-transfer-plan.md).
  def compiled_code
    box = refs[:codebox]
    source = box ? box[:value].to_s : ""
    PicoRubyVM::InstructionSequence.compile(source).to_binary
  rescue Exception => e
    raise "コンパイルできませんでした（#{e.message}）。文法の誤りは Run で場所が分かります"
  end

  def on_device_run_mrb(_event)
    patch(device: :busy, status: "コンパイルして実機に送っています…", kind: "busy")
    Task.new(name: "device-run-mrb") do
      begin
        $device.run_mrb($app.compiled_code)
        $app.device_finished(nil) if $app
      rescue Exception => e
        $app.device_finished(e) if $app
      end
    end
    nil
  end

  def on_device_install_mrb(_event)
    patch(device: :busy, status: "コンパイルして実機の #{DeviceLink::APP_MRB_PATH} に書いています…", kind: "busy")
    Task.new(name: "device-install-mrb") do
      begin
        $device.install_mrb($app.compiled_code)
        $app.device_installed_mrb(nil) if $app
      rescue Exception => e
        $app.device_installed_mrb(e) if $app
      end
    end
    nil
  end

  def device_installed_mrb(error)
    patch(device: $device.connected? ? :connected : :none)
    if error
      report("実機の app.mrb にする", error)
    else
      patch(kind: "ok", status: "#{DeviceLink::APP_MRB_PATH} に書いて実行しています。電源を入れるたびにこのプログラムが動きます。")
    end
    nil
  end

  def on_advanced_toggle(_event)
    @advanced_visible = !@advanced_visible
    refresh
    nil
  end

  # Takes away what the page may have left in /lib and has the firmware
  # write the library again at the next start.
  def on_device_reset_lib(_event)
    patch(device: :busy, status: "実機のライブラリを初期設定に戻しています…", kind: "busy")
    Task.new(name: "device-reset-lib") do
      begin
        paths = []
        i = 0
        while i < SimApp::LIB_FILES.size
          paths << "/lib/#{SimApp::LIB_FILES[i]}"
          i += 1
        end
        removed = $device.reset_library(paths)
        $app.device_reset_lib(removed, nil) if $app
      rescue Exception => e
        $app.device_reset_lib(nil, e) if $app
      end
    end
    nil
  end

  def device_reset_lib(removed, error)
    patch(device: $device.connected? ? :connected : :none)
    if error
      report("ライブラリを初期設定に戻す", error)
      return nil
    end
    done = removed.empty? ? "" : "#{removed.size} 個の余分なファイルを消しました。"
    $device.log("ライブラリを初期設定に戻します。#{done}")
    @before_restart = "ライブラリを初期設定に戻しました。#{done}"
    patch(kind: "busy", status: "#{done}実機を再起動しています。起動するときにファームウェアがライブラリを書き直します。" \
                                "起動し終わると自動でつなぎ直します。")
    nil
  end

  def device_updated_lib(result, error)
    patch(device: $device.connected? ? :connected : :none)
    if error
      report("ライブラリを最新にする", error)
      return nil
    end
    rewritten = result[0]
    removed = result[1]
    was = result[2] || FIRST_LIB_VERSION
    if rewritten.empty? && removed.empty?
      patch(kind: "ok", status: "実機のライブラリは最新（#{lib_version} 版）です。変更はありません。")
      return nil
    end
    names = []
    i = 0
    while i < rewritten.size
      names << rewritten[i].split("/").last
      i += 1
    end
    # The same name on both sides when lib/ changed without its date.
    done = was == lib_version ? "実機のライブラリを #{lib_version} 版にそろえました。" :
                                "実機のライブラリを #{was} 版から #{lib_version} 版にしました。"
    done += "#{names.join('、')} を新しくしました。" unless names.empty?
    done += "#{removed.size} 個の .mrb を消しました。" unless removed.empty?
    $device.log(done)
    @before_restart = done
    patch(kind: "busy", status: "#{done}実機を再起動しています。起動し終わると自動でつなぎ直します。")
    nil
  end

  def device_finished(error)
    state_now = $device.connected? ? :connected : :none
    if error
      patch(device: state_now)
      report("実機で実行", error)
    else
      patch(device: state_now, kind: "ok",
            status: "実機で実行しています。止めるには、端末で Ctrl-C を押すか、実機を再起動してください。")
    end
    nil
  end

  def on_lib_toggle(_event)
    @lib_visible = !@lib_visible
    @lib_file ||= LIB_FILES[0]
    @lib_shown = nil
    refresh
    nil
  end

  def on_lib_file(event)
    @lib_file = event.target[:value].to_s
    @lib_shown = nil
    nil
  end

  # Fetched once per file, coloured like the code box, and put into the
  # <pre> on the heartbeat once it is there (it appears a render later).
  def draw_lib_code
    return nil unless @lib_visible
    el = refs[:lib_code]
    return nil unless el
    file = @lib_file
    return nil if file == @lib_shown
    # Only this hash is touched inside the fetch's block: a block handed to
    # JS may not run with this component as self.
    texts = (@lib_texts ||= {})
    text = texts[file]
    if text.nil?
      return nil if texts.key?("fetching #{file}")
      texts["fetching #{file}"] = true
      JS.global.fetch("#{JS.global[:REPO_ROOT].to_s}lib/#{file}", { cache: "no-store" }) do |response|
        begin
          texts[file] = response[:ok] ? response.text.await.to_s : "# #{file}: #{response[:status].to_i}"
        rescue Exception => e
          texts[file] = "# #{file}: #{e.class}: #{e.message}"
        end
      end
      return nil
    end
    html = begin
      CodeColors.html(text)
    rescue Exception
      CodeColors.escape(text)   # a wasm without SyntaxHighlight
    end
    el[:innerHTML] = html
    el[:scrollTop] = 0
    @lib_shown = file
    nil
  end

  def on_notes_toggle(_event)
    patch(notes_visible: !state[:notes_visible])
    nil
  end

  # Has to run on the click's own stack (nothing awaited before it): that is
  # the only place the browser lifts its autoplay block. Once is enough. A
  # page that cannot make sound still runs the program, and the note log
  # still shows what would have played.
  def enable_audio
    return if $audio_sink.backend
    web = WebAudioSpeaker.new
    web.resume
    $audio_sink.backend = web
    nil
  rescue Exception => e
    JS.global[:console].error("音を有効にできませんでした: #{e.class}: #{e.message}")
    nil
  end

  # --- work ----------------------------------------------------------------

  def run(source)
    begin
      SimApp.stop_task
      AdventureBoard.speaker.stop
      $notelog.clear
      SimApp.start_task(source)
      patch(status: "実行中", kind: "ok")
    rescue Exception => e
      # Exception, not StandardError: a syntax error in the typed code is a
      # ScriptError and would otherwise kill the task without a word.
      report("実行エラー", e)
    end
    nil
  end

  def report(prefix, e)
    message = "#{prefix}: #{e.class}: #{e.message}"
    patch(status: message, kind: "error")
    JS.global[:console].error(message)
    nil
  end

  def draw
    JS.global.renderPanel($panel.levels_hex)
    draw_breadboard
    draw_lib_code
    draw_status_led
    draw_notes
    draw_device
    draw_code_colors
    nil
  end

  # The code box in colour. Read on the heartbeat like everything else, and
  # only worked out again when the text is not what was coloured last: that
  # covers typing, a pasted program and a loaded example alike, with nobody
  # having to say so. SyntaxHighlight comes with `rake sim:wasm`; the stock
  # package does not have it, and then the box stays as plain as it was.
  def draw_code_colors
    return if @code_colors_missing
    box = refs[:codebox]
    return unless box
    source = box[:value].to_s
    return if source == @colored_source
    @colored_source = source
    JS.global.setCodeColors(CodeColors.html(source))
    nil
  rescue Exception => e
    # Once, not twenty times a second. A wasm without SyntaxHighlight lands
    # here with a NameError, and that one is expected and not worth a line.
    @code_colors_missing = true
    puts "code colours are off: #{e.class}: #{e.message}" unless e.is_a?(NameError)
    nil
  end

  # The log is read on the heartbeat, like the notes. So is a cable pulled out:
  # the port goes away without anyone clicking anything.
  def draw_device
    if state[:device] == :connected && !$device.connected?
      patch(device: :none, kind: "busy",
            status: "実機との接続が切れました。再起動や挿し直しなら、戻ってきたら自動でつなぎ直します。")
    elsif state[:device] == :none && $device.connected?
      # The link came back without anyone clicking (DeviceLink#watch_for_return).
      # What was done before the restart is said again: the restart took it
      # off the status line, and the board's start-up off the terminal.
      done = @before_restart
      @before_restart = nil
      $device.log(done) if done
      patch(device: :connected, status: "実機につなぎ直しました。#{done}", kind: "ok")
    end
    nil
  end

  # The board's shell lives in an xterm.js terminal (index.html makes it),
  # and what is typed there goes to the board through the link.
  def wire_device
    return nil unless state[:device_supported]
    term = JS.global.deviceTerminal
    return nil unless term
    $device = DeviceLink.new(term)
    term.onData do |data|
      $device.type(data.to_s)
    end
    nil
  end

  # Read on the heartbeat like the panel: the board layer drives the pin and
  # the page shows whatever it currently is.
  def draw_status_led
    el = refs[:status_led]
    return nil unless el
    led = $board.status_led
    lit = led && led.on?
    return nil if lit == $status_led_shown
    $status_led_shown = lit
    el[:className] = lit ? "led green" : "led green off"
    nil
  end

  def draw_notes
    el = refs[:notes]
    return nil unless el
    text = $notelog.to_s
    return nil if text == $notes_shown
    $notes_shown = text
    el[:textContent] = text
    el[:scrollTop] = el[:scrollHeight].to_i
    nil
  end

  # The panel is redrawn on a heartbeat rather than by whoever changed it,
  # which is what a real one does: the driver scans it continuously and the
  # display shows whatever the chips currently hold. It means the code typed
  # into the page never has to tell the simulator to repaint, and a melody
  # playing in its own task still gets its notes shown.
  def start_monitor
    JS.global.setTimeout(MONITOR_MS) do
      begin
        draw
      rescue Exception
        nil
      end
      start_monitor
    end
    nil
  end

  # Arrow keys and Z / X are the board's buttons -- unless the keys are going
  # somewhere else: the code box, or the terminal (xterm has a hidden textarea
  # of its own).
  def wire_keyboard
    JS.document.addEventListener('keydown') do |event|
      pin = KEY_PINS[event[:key].to_s]
      hold(pin, true) if pin && !typing?(event)
    end
    JS.document.addEventListener('keyup') do |event|
      pin = KEY_PINS[event[:key].to_s]
      hold(pin, false) if pin && !typing?(event)
    end
    nil
  end

  def typing?(event)
    tag = event[:target][:tagName].to_s
    tag == "TEXTAREA" || tag == "INPUT"
  rescue Exception
    false
  end

  def load_example(path)
    device_only = path.start_with?("device:")
    url = device_only ? "#{JS.global[:REPO_ROOT].to_s}examples/#{path[7, path.size - 7]}" : "examples/#{path}"
    # What a device-only sample looked like when loaded, for on_run. Only this
    # hash is touched inside the fetch's block (see draw_lib_code).
    device = (@device_example ||= {})
    device[:source] = nil
    # no-store: a hard reload only bypasses the cache for the document and what
    # it loads directly. A fetch the page makes afterwards still goes through
    # the HTTP cache, so an edited example would keep coming back stale however
    # many times the page was reloaded.
    JS.global.fetch(url, { cache: "no-store" }) do |response|
      begin
        if response[:ok]
          box = refs[:codebox]
          text = response.text.await.to_s
          box[:value] = text if box
          if device_only
            device[:source] = text
            patch(status: DEVICE_ONLY, kind: "busy")
          end
          use_example_wiring(text)
        else
          report("サンプルの取得", RuntimeError.new("#{path}: #{response[:status].to_i}"))
        end
      rescue Exception => e
        report("サンプルの取得", e)
      end
    end
    nil
  end

  # The run loop is a class method — it outlives any one render — and it pokes
  # the mounted instance, so these two cannot stay private.
  public :draw, :report, :device_finished, :device_rebooting, :device_installed, :device_cleared,
         :device_updated_lib, :device_reset_lib, :compiled_code, :device_installed_mrb
end

Funicular.start(SimApp, container: 'app')
