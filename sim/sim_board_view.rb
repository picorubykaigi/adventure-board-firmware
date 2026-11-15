# The board as the page shows it: KiCad's picture of the assembled board
# (sim/board/board.webp) with what changes laid over it where it sits on the
# real one -- the LED matrix, the buttons, the status LED, and whatever is
# plugged into the breadboard.
#
# Everything is placed in millimetres from BoardLayout and written as
# percentages of the picture, so the whole thing scales with the box it is
# in. Zooming shows a smaller piece of the same picture in a box that is as
# wide or wider: the LED matrix, or the breadboard with J1 beside it.
#
# Mixed into SimApp: the handlers named here are SimApp's.
#
# What the view is showing and the breadboard's editing (the part picked, the
# first leg's hole, the message) live in instance variables rather than in
# Funicular's state, and a change asks for a render with #refresh. A click is
# handled in a task of its own, and Funicular drops a patch that arrives while
# another is still rendering: a click right after picking a part landed with
# the old part picked, or not at all. Read from here, the values are always
# the latest; a render that was dropped is asked for again on the heartbeat.
module BoardView
  BOARD_W = BoardLayout::SIZE[0]
  BOARD_H = BoardLayout::SIZE[1]
  PITCH = BoardLayout::BREADBOARD_PITCH
  BB_CENTER = BoardLayout::BREADBOARD_CENTER

  # The #panel canvas is 452 px: a 4 px border, then 16 cells 28 px apart,
  # centres 13 px into each. Its 16 centres have to land on the LEDs'.
  PANEL_PX = 452
  PANEL_MM = PANEL_PX * BoardLayout::MATRIX_PITCH / 28.0
  PANEL_LEFT = BoardLayout::MATRIX_ORIGIN[0] - 17 * BoardLayout::MATRIX_PITCH / 28.0
  PANEL_TOP = BoardLayout::MATRIX_ORIGIN[1] - 17 * BoardLayout::MATRIX_PITCH / 28.0

  # [x, y, width, height] in mm, and the widest the box may be.
  VIEWS = {
    full: [0.0, 0.0, BOARD_W, BOARD_H, 460],
    matrix: [PANEL_LEFT - 3, PANEL_TOP - 3, PANEL_MM + 6, PANEL_MM + 6, 460],
    breadboard: [24.0, 65.5, 66.0, 39.0, 900]
  }
  # The parts are drawn on a canvas over the breadboard view's area only.
  PARTS_AREA = VIEWS[:breadboard]
  PARTS_PX_PER_MM = 20

  TOOLS = [
    ["press", "動かす・押す"],
    ["wire", "ジャンパ線"],
    ["resistor", "抵抗 1kΩ"],
    ["led", "青 LED"],
    ["switch", "タクトスイッチ"],
    ["remove", "外す"]
  ]

  STORAGE_KEY = "adventure-board-breadboard"

  # --- geometry ------------------------------------------------------------

  def self.pct(mm, of)
    "#{(mm * 100.0 / of).round(4)}%"
  end

  # Absolute placement of a box given in mm on the picture.
  def self.box_style(x, y, w, h)
    "left:#{pct(x, BOARD_W)};top:#{pct(y, BOARD_H)};width:#{pct(w, BOARD_W)};height:#{pct(h, BOARD_H)}"
  end

  def self.centered_style(x, y, w, h)
    box_style(x - w / 2.0, y - h / 2.0, w, h)
  end

  # Where a hole is, in mm on the picture.
  def self.hole_xy(name)
    h = Breadboard.parse_hole(name)
    return nil unless h
    if h[0] == :j1
      pin = BoardLayout::J1_PINS[h[1]]
      return [pin[0], pin[1]]
    end
    [BB_CENTER[0] + (h[1] - 9) * PITCH,
     BB_CENTER[1] + BoardLayout::BREADBOARD_ROWS[h[0]] * PITCH]
  end

  def self.view_style(zoom)
    v = VIEWS[zoom]
    "width:min(#{v[4]}px, calc(100vw - 32px));aspect-ratio:#{v[2]} / #{v[3]}"
  end

  def self.board_style(zoom)
    v = VIEWS[zoom]
    "width:#{(BOARD_W * 100.0 / v[2]).round(4)}%;aspect-ratio:#{BOARD_W} / #{BOARD_H};" \
      "transform:translate(-#{pct(v[0], BOARD_W)}, -#{pct(v[1], BOARD_H)})"
  end

  # --- render --------------------------------------------------------------

  def board_view
    zoom = view_zoom
    div(class: "controls zoom-tabs") do
      zoom_tab(:full, "基板全体")
      zoom_tab(:matrix, "LED マトリクス")
      zoom_tab(:breadboard, "ブレッドボード")
    end
    view_class = @dot_art_editor_on ? "zoom-#{zoom} dot-art-editor" : "zoom-#{zoom}"
    view_style = BoardView.view_style(zoom)
    view_style += ";--pen-cursor:#{DotArtEditor.pen_cursor(@dot_pen)}" if @dot_art_editor_on
    div(id: "board-view", class: view_class, style: view_style) do
      div(id: "board", style: BoardView.board_style(zoom)) do
        img(src: "board/board.webp", class: "board-img", alt: "Adventure Board", draggable: "false")
        board_leds
        board_buttons
        parts_layer
        canvas(ref: :panel, id: "panel", width: PANEL_PX.to_s, height: PANEL_PX.to_s,
               style: BoardView.box_style(PANEL_LEFT, PANEL_TOP, PANEL_MM, PANEL_MM),
               onclick: :on_zoom_matrix, onmousedown: :on_matrix_press,
               onmousemove: :on_matrix_drag)
      end
    end
    breadboard_tools if zoom == :breadboard
    dot_art_editor_controls if zoom == :matrix
    breadboard_warnings
  end

  private

  def view_zoom
    @zoom || :full
  end

  def view_tool
    @tool || "press"
  end

  # Asks for a render, and asks again on the heartbeat if this one is
  # dropped (see the top of this file).
  def refresh
    @refresh_wanted = true
    return nil if @updating
    @refresh_wanted = false
    patch(bb_version: state[:bb_version] + 1)
    nil
  end

  def zoom_tab(zoom, text)
    klass = view_zoom == zoom ? "tab on" : "tab"
    button(class: klass, "data-zoom": zoom.to_s, onclick: :on_zoom) { text }
  end

  def board_leds
    s = BoardLayout::STATUS_LED
    # Same id and classes as before the board picture: the headless check
    # reads the class to see it blink.
    span(ref: :status_led, id: "status-led", class: "led green off",
         style: BoardView.centered_style(s[0], s[1], 2.4, 1.6)) { "" }
    p = BoardLayout::POWER_LED
    span(class: "led red", style: BoardView.centered_style(p[0], p[1], 1.9, 1.1)) { "" }
  end

  # Round caps over the six tact switches; the pins are what GPIO reads.
  def board_buttons
    list = BoardLayout::BUTTONS
    i = 0
    while i < list.size
      b = list[i]
      klass = state[:held].include?(b[1]) ? "board-btn held" : "board-btn"
      div(class: klass, "data-pin": b[1].to_s, title: b[0],
          style: BoardView.centered_style(b[2][0], b[2][1], 7.0, 7.0),
          onmousedown: :on_press, onmouseup: :on_release,
          onmouseleave: :on_release, ontouchstart: :on_press,
          ontouchend: :on_release) { "" }
      i += 1
    end
    nil
  end

  def parts_layer
    a = PARTS_AREA
    canvas(id: "parts", width: (a[2] * PARTS_PX_PER_MM).to_i.to_s,
           height: (a[3] * PARTS_PX_PER_MM).to_i.to_s,
           style: BoardView.box_style(a[0], a[1], a[2], a[3]))
    if view_zoom == :breadboard
      # One element for every hole: a click says where, and the nearest hole
      # is worked out from that. 190 elements of their own made each render
      # slow enough for clicks to be lost (see the top of this file).
      div(id: "holes", class: "hole-area",
          style: BoardView.box_style(a[0], a[1], a[2], a[3]),
          onclick: :on_hole_area) { "" }
    else
      div(class: "bb-area", title: "ブレッドボードを大きくする",
          style: BoardView.box_style(a[0], a[1], a[2], a[3]),
          onclick: :on_zoom_breadboard) { "" }
    end
    switch_caps
  end

  # The hole nearest a point on the picture, within reach of it; nil when
  # the point is between holes or off the breadboard.
  def self.hole_near(x, y)
    reach = 1.3
    col = ((x - BB_CENTER[0]) / PITCH).round + 9
    rows = BoardLayout::BREADBOARD_ROWS
    r = 0
    while r < rows.size
      if 1 <= col && col <= Breadboard::COLUMNS
        name = Breadboard.hole_name(r, col)
        xy = hole_xy(name)
        return name if (xy[0] - x).abs <= reach && (xy[1] - y).abs <= reach
      end
      r += 1
    end
    n = 1
    while n <= 20
      pin = BoardLayout::J1_PINS[n]
      return "J1-#{n}" if (pin[0] - x).abs <= reach && (pin[1] - y).abs <= reach
      n += 1
    end
    nil
  end

  # Tact switches on the breadboard are pressed like the board's own. Always
  # inside one box, so that plugging one in or out does not shift the
  # elements after it: Funicular matches elements by position, and a shift
  # made it build the LED matrix's canvas anew, which renderPanel went on
  # not drawing into.
  def switch_caps
    div(class: "switch-caps") { switch_cap_list }
  end

  def switch_cap_list
    bb = Breadboard.current
    parts = bb.parts
    i = 0
    while i < parts.size
      p = parts[i]
      i += 1
      next unless p[1] == "switch"
      a = BoardView.hole_xy(p[2][0])
      d = BoardView.hole_xy(p[2][3])
      klass = bb.pressed?(p[0]) ? "bb-switch held" : "bb-switch"
      div(class: klass, "data-part": p[0].to_s,
          style: BoardView.centered_style((a[0] + d[0]) / 2.0, (a[1] + d[1]) / 2.0, 6.0, 6.0),
          onmousedown: :on_switch_down, onmouseup: :on_switch_up,
          onmouseleave: :on_switch_up, ontouchstart: :on_switch_down,
          ontouchend: :on_switch_up) { "" }
    end
    nil
  end

  def breadboard_tools
    div(class: "controls shelf") do
      list = TOOLS
      i = 0
      while i < list.size
        klass = view_tool == list[i][0] ? "tool on" : "tool"
        button(class: klass, "data-tool": list[i][0], onclick: :on_tool) { list[i][1] }
        i += 1
      end
      button(class: "tool", onclick: :on_clear_breadboard) { "全部外す" }
    end
    div(id: "bb-message", class: "legend") { @bb_msg.to_s }
    button(id: "bb-text-toggle", class: "disclosure", onclick: :on_bb_text_toggle) do
      @bb_text_visible ? "▾ 配線を文字で" : "▸ 配線を文字で見る・貼り付ける"
    end
    if @bb_text_visible
      textarea(ref: :bbtext, id: "bb-text", spellcheck: "false")
      div(class: "controls") do
        button(id: "bb-text-apply", onclick: :on_bb_text_apply) { "この配線にする" }
      end
    end
  end

  def breadboard_warnings
    list = @bb_warnings
    return nil if list.nil? || list.empty?
    div(id: "bb-warnings") do
      i = 0
      while i < list.size
        div(class: "warning") { "⚠ #{list[i]}" }
        i += 1
      end
    end
  end

  # --- handlers ------------------------------------------------------------

  def on_zoom(event)
    set_zoom(event.target.getAttribute('data-zoom').to_s)
  end

  def on_zoom_matrix(_event)
    set_zoom("matrix") unless view_zoom == :matrix
  end

  def on_matrix_press(event)
    on_dot_art_editor_press(event) if view_zoom == :matrix && @dot_art_editor_on
  end

  def on_matrix_drag(event)
    on_dot_art_editor_drag(event) if view_zoom == :matrix && @dot_art_editor_on
  end

  def on_zoom_breadboard(_event)
    set_zoom("breadboard")
  end

  def set_zoom(name)
    zoom = name == "matrix" ? :matrix : (name == "breadboard" ? :breadboard : :full)
    @zoom = zoom
    @pending = nil
    @moving = nil
    @bb_msg = tool_hint(view_tool)
    @parts_shown = nil
    # The dot art editor's text box is made anew when the LED matrix view
    # comes back, and would stay empty until the next dot.
    @dot_art_editor_text_stale = true
    refresh
  end

  def on_tool(event)
    tool = event.target.getAttribute('data-tool').to_s
    @tool = tool
    @pending = nil
    @moving = nil
    @bb_msg = tool_hint(tool)
    @parts_shown = nil
    refresh
  end

  def tool_hint(tool)
    case tool
    when "wire" then "線の片方の端を挿す穴を押してください（J1 の穴も使えます）"
    when "resistor" then "抵抗の 1 本目の足を挿す穴を押してください"
    when "led" then "LED の長い足（＋、アノード）を挿す穴を押してください"
    when "switch" then "スイッチは溝をまたいで挿します。e の段の、左上の足の穴を押してください"
    when "remove" then "外したい部品の足の穴か、スイッチを押してください"
    else "足の挿さった穴を押すと、その足を挿し直せます。スイッチは押せます。部品を足すときは上で選んでください"
    end
  end

  def on_hole_area(event)
    el = event.target
    w = el[:clientWidth].to_f
    h = el[:clientHeight].to_f
    return nil if w <= 0 || h <= 0
    a = PARTS_AREA
    x = a[0] + event[:offsetX].to_f / w * a[2]
    y = a[1] + event[:offsetY].to_f / h * a[3]
    hole = BoardView.hole_near(x, y)
    on_hole(hole) if hole
    nil
  end

  def on_hole(hole)
    bb = Breadboard.current
    tool = view_tool
    if tool == "press"
      move_leg(bb, hole)
    elsif tool == "remove"
      id = part_at(bb, hole)
      if id
        bb.remove(id)
        breadboard_changed("外しました")
      end
    elsif tool == "switch"
      result = bb.place(:switch, [hole])
      breadboard_changed(result.is_a?(String) ? result : "挿しました。スイッチを押すと、左右の列がつながります")
    elsif tool == "wire" || tool == "resistor" || tool == "led"
      first = @pending
      if first.nil?
        if bb.occupied?(hole)
          @bb_msg = "#{hole} にはもう挿さっています"
        else
          second = tool == "led" ? "短い足（−、カソード）" : "もう片方"
          @pending = hole
          @bb_msg = "#{hole} に挿しました。#{second}を挿す穴を押してください"
          @parts_shown = nil
        end
        refresh
      else
        result = bb.place(tool, [first, hole])
        @pending = nil
        breadboard_changed(result.is_a?(String) ? result : "挿しました。#{tool_hint(tool)}")
      end
    end
    nil
  end

  # The first click lifts the leg in a hole, the second puts it in another;
  # the same hole again puts it back where it was.
  def move_leg(bb, hole)
    if @moving
      from = @pending
      id, k = @moving
      @moving = nil
      @pending = nil
      if hole == from
        @bb_msg = "やめました"
        @parts_shown = nil
        return refresh
      end
      result = bb.move_leg(id, k, hole)
      return breadboard_changed(result ? result : "#{from} から #{hole} に挿し直しました")
    end
    leg = bb.leg_at(hole)
    if leg.nil?
      @bb_msg = tool_hint("press")
      return refresh
    end
    if bb.part(leg[0])[1] == "switch"
      @bb_msg = "スイッチは「外す」で外してから挿し直してください"
      return refresh
    end
    @moving = leg
    @pending = hole
    @bb_msg = "#{hole} の足を持ち上げました。挿し直す穴を押してください（同じ穴を押すとやめます）"
    @parts_shown = nil
    refresh
  end

  def part_at(bb, hole)
    parts = bb.parts
    i = 0
    while i < parts.size
      return parts[i][0] if parts[i][2].include?(hole)
      i += 1
    end
    nil
  end

  def on_switch_down(event)
    id = event.target.getAttribute('data-part').to_s.to_i
    bb = Breadboard.current
    if view_tool == "remove"
      bb.remove(id)
      breadboard_changed("外しました")
    else
      bb.press(id)
      refresh
    end
    nil
  end

  def on_switch_up(event)
    id = event.target.getAttribute('data-part').to_s.to_i
    bb = Breadboard.current
    return nil unless bb.pressed?(id)
    bb.release(id)
    refresh
    nil
  end

  def on_clear_breadboard(_event)
    Breadboard.current.clear
    breadboard_changed("全部外しました")
  end

  def on_bb_text_toggle(_event)
    @bb_text_visible = !@bb_text_visible
    refresh
    # The box appears on the next render; the heartbeat fills it then.
    @bb_text_empty = true
    nil
  end

  def on_bb_text_apply(_event)
    box = refs[:bbtext]
    return nil unless box
    errors = Breadboard.current.load_text(box[:value].to_s)
    breadboard_changed(errors.empty? ? "配線しました" : errors.join(" / "))
  end

  def breadboard_changed(message)
    save_breadboard
    @bb_msg = message
    @parts_shown = nil
    refresh
    fill_bb_text
    nil
  end

  # --- heartbeat -----------------------------------------------------------

  # What is plugged in, and how brightly each LED shines, drawn by JS in one
  # call (renderParts in index.html) when it differs from what was drawn.
  def draw_breadboard
    bb = Breadboard.current
    spec = parts_spec(bb)
    unless spec == @parts_shown
      @parts_shown = spec
      JS.global.renderParts(spec)
    end
    warnings = bb.warnings
    unless warnings == @bb_warnings
      @bb_warnings = warnings
      refresh
    end
    refresh if @refresh_wanted
    fill_bb_text if @bb_text_empty
    nil
  end

  # One line per part: kind, the legs in canvas pixels, then what the kind
  # needs (a wire's colour, an LED's brightness, whether a switch is down).
  def parts_spec(bb)
    out = labels_spec + strips_spec
    parts = bb.parts
    i = 0
    while i < parts.size
      p = parts[i]
      i += 1
      legs = p[2]
      out << p[1]
      j = 0
      while j < legs.size
        xy = BoardView.hole_xy(legs[j])
        out << " " << ((xy[0] - PARTS_AREA[0]) * PARTS_PX_PER_MM).round.to_s
        out << " " << ((xy[1] - PARTS_AREA[1]) * PARTS_PX_PER_MM).round.to_s
        j += 1
      end
      if p[1] == "led"
        out << " " << bb.led_brightness(p[0]).round(3).to_s
      elsif p[1] == "switch"
        out << (bb.pressed?(p[0]) ? " 1" : " 0")
      elsif p[1] == "wire"
        out << " " << wire_color(legs, i)
      end
      out << "\n"
    end
    if @pending
      xy = BoardView.hole_xy(@pending)
      out << "pending " << ((xy[0] - PARTS_AREA[0]) * PARTS_PX_PER_MM).round.to_s
      out << " " << ((xy[1] - PARTS_AREA[1]) * PARTS_PX_PER_MM).round.to_s << "\n"
    end
    out
  end

  # The names the wiring is written in (c9, J1 aside): the columns' numbers
  # above a and below j, the rows' letters left of 1 and right of 17, one
  # pitch out from the holes. The real breadboard has none printed; they are
  # here so that a13 can be found by eye. Never changes, so built once.
  def labels_spec
    return @labels_spec if @labels_spec
    out = ""
    c = 1
    while c <= Breadboard::COLUMNS
      top = BoardView.hole_xy(Breadboard.hole_name(0, c))
      bottom = BoardView.hole_xy(Breadboard.hole_name(9, c))
      out << label_line(top[0], top[1] - PITCH, c.to_s)
      out << label_line(bottom[0], bottom[1] + PITCH, c.to_s)
      c += 1
    end
    r = 0
    while r < 10
      left = BoardView.hole_xy(Breadboard.hole_name(r, 1))
      right = BoardView.hole_xy(Breadboard.hole_name(r, Breadboard::COLUMNS))
      letter = "abcdefghij"[r]
      out << label_line(left[0] - PITCH, left[1], letter)
      out << label_line(right[0] + PITCH, right[1], letter)
      r += 1
    end
    @labels_spec = out
  end

  def label_line(x, y, text)
    "label " + ((x - PARTS_AREA[0]) * PARTS_PX_PER_MM).round.to_s + " " +
      ((y - PARTS_AREA[1]) * PARTS_PX_PER_MM).round.to_s + " " + text + "\n"
  end

  # The five holes of each strip, joined by a line: what a beginner cannot
  # see inside the breadboard. Separate above and below the groove, which is
  # the other half of the lesson. The strip of the hole a leg is waiting on
  # is drawn stronger ("hot"): anywhere along it is the same.
  def strips_spec
    hot = nil
    if @pending
      h = Breadboard.parse_hole(@pending)
      hot = [h[0] < 5 ? 0 : 5, h[1]] if h && h[0] != :j1
    end
    out = ""
    c = 1
    while c <= Breadboard::COLUMNS
      first = 0
      while first < 10
        a = BoardView.hole_xy(Breadboard.hole_name(first, c))
        b = BoardView.hole_xy(Breadboard.hole_name(first + 4, c))
        out << (hot == [first, c] ? "hot" : "strip")
        out << " " << ((a[0] - PARTS_AREA[0]) * PARTS_PX_PER_MM).round.to_s
        out << " " << ((a[1] - PARTS_AREA[1]) * PARTS_PX_PER_MM).round.to_s
        out << " " << ((b[0] - PARTS_AREA[0]) * PARTS_PX_PER_MM).round.to_s
        out << " " << ((b[1] - PARTS_AREA[1]) * PARTS_PX_PER_MM).round.to_s << "\n"
        first += 5
      end
      c += 1
    end
    out
  end

  # Red to a supply, black to ground, and otherwise the colours a jumper kit
  # comes in, in turn.
  WIRE_COLORS = ["#f2c230", "#3b82f6", "#22a35a", "#f28c28", "#e5e5e5"]

  def wire_color(legs, n)
    a = Breadboard.node_of(legs[0])
    b = Breadboard.node_of(legs[1])
    return "#e0342f" if a == "3V3" || a == "5V" || b == "3V3" || b == "5V"
    return "#222222" if a == "GND" || b == "GND"
    WIRE_COLORS[n % WIRE_COLORS.size]
  end

  # A sample that says in its comments how it is wired gets that wiring, and
  # the breadboard is shown so that it can be seen.
  def use_example_wiring(source)
    text = Breadboard.wiring_in(source)
    if text.nil?
      # A sample without wiring is about the board itself; zoomed in on the
      # breadboard, the LED matrix it draws on would be out of sight.
      set_zoom("full") if view_zoom == :breadboard
      return nil
    end
    Breadboard.current.load_text(text)
    save_breadboard
    @zoom = :breadboard
    @pending = nil
    @bb_msg = "サンプルの配線にしました"
    @parts_shown = nil
    refresh
    fill_bb_text
    nil
  end

  # --- keeping it --------------------------------------------------------------

  # Per viewer, in this browser: what they built last time comes back.
  def load_breadboard
    text = nil
    begin
      v = JS.global[:localStorage].getItem(STORAGE_KEY)
      text = v.to_s unless v.nil?
    rescue Exception
      text = nil
    end
    return nil if text.nil? || text.empty? || text == "null"
    Breadboard.current.load_text(text)
    nil
  end

  def save_breadboard
    JS.global[:localStorage].setItem(STORAGE_KEY, Breadboard.current.to_text)
    nil
  rescue Exception
    nil
  end

  def fill_bb_text
    box = refs[:bbtext]
    @bb_text_empty = box.nil?
    return nil unless box
    box[:value] = Breadboard.current.to_text
    nil
  end

  public :board_view, :draw_breadboard, :load_breadboard, :use_example_wiring
end
