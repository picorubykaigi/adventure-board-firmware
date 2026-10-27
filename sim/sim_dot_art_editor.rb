# Drawing a picture on the LED matrix by clicking its dots, written out as
# rows of strings: one digit per dot, 1 to 9, '.' when it is off. A program
# reads a dot back with `c.to_i * 255 / 9`, which is 0 for '.' too.
#
# The dots go through the board layer's LedMatrix, so they look as they
# would on the board. Whatever the code box was running is stopped first;
# it would draw over them.
#
# Mixed into SimApp like BoardView, and kept in instance variables for the
# same reason (see the top of sim_board_view.rb).
module DotArtEditor
  WIDTH = LedMatrix::WIDTH
  HEIGHT = LedMatrix::HEIGHT
  BRIGHTEST = 9

  # The #panel canvas's cells, in its own pixels: a 3 px edge, then 28 px each.
  CELL_EDGE_PX = 3
  CELL_PX = 28

  def self.text(levels)
    out = "[\n"
    y = 0
    while y < HEIGHT
      out << '  "'
      x = 0
      while x < WIDTH
        level = levels[y * WIDTH + x]
        out << (level == 0 ? '.' : level.to_s)
        x += 1
      end
      out << (y == HEIGHT - 1 ? "\"\n" : "\",\n")
      y += 1
    end
    out << ']'
  end

  # 1-based, like LedMatrix#set; 0 or 17 on the canvas's edge.
  def self.dot_at(px)
    ((px - CELL_EDGE_PX) / CELL_PX).floor + 1
  end

  # LedMatrix#set's 0..255.
  def self.brightness(level)
    level * 255 / BRIGHTEST
  end

  # A swatch as light as the LEDs show the level: the canvas draws them
  # linear in it (see Panel#level_at).
  def self.pen_style(level)
    v = DotArtEditor.brightness(level)
    ink = if level <= BRIGHTEST / 2
      '#fff'
    else
      '#222'
    end
    "background:rgb(#{v},#{v},#{v});color:#{ink}"
  end

  # The pointer over the LED matrix is an LED lit to the pen's brightness,
  # or a dark one crossed out for the pen that turns dots off. Its hot spot
  # is the middle.
  def self.pen_cursor(level)
    v = DotArtEditor.brightness(level)
    color = "rgb(#{v},#{v},#{v})"
    shape = if level == 0
      "<circle cx='16' cy='16' r='9' fill='#3a3a3a' stroke='#26242f' stroke-width='2'/>" \
        "<path d='M11 11L21 21M21 11L11 21' stroke='#fff' stroke-width='2'/>"
    else
      "<circle cx='16' cy='16' r='14' fill='#{color}' opacity='.35'/>" \
        "<circle cx='16' cy='16' r='9' fill='#{color}' stroke='#26242f' stroke-width='2'/>"
    end
    svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>#{shape}</svg>"
    encoded = svg.gsub('#', '%23').gsub('<', '%3C').gsub('>', '%3E')
    "url(\"data:image/svg+xml,#{encoded}\") 16 16, crosshair"
  end

  private

  def dot_art_editor_controls
    div(class: 'controls shelf') do
      klass = @dot_art_editor_on ? 'tool on' : 'tool'
      button(id: 'dot-art-editor-toggle', class: klass, onclick: :on_dot_art_editor_toggle) { 'ドット絵エディタ' }
      if @dot_art_editor_on
        button(id: 'dot-art-editor-clear', class: 'tool', onclick: :on_dot_art_editor_clear) { 'クリア' }
        button(id: 'dot-art-editor-copy', class: 'tool', onclick: :on_dot_art_editor_copy) { @dot_art_editor_copied ? 'コピーしました' : 'コピー' }
      end
    end
    if @dot_art_editor_on
      div(class: 'controls pens') { pen_buttons }
      textarea(ref: :dot_art_editor_text, id: 'dot-art-editor-text', readonly: 'readonly', spellcheck: 'false')
    end
  end

  def pen_buttons
    level = BRIGHTEST
    while 0 <= level
      klass = level == @dot_pen ? 'pen on' : 'pen'
      button(class: klass, 'data-level': level.to_s, style: DotArtEditor.pen_style(level), onclick: :on_dot_art_editor_pen) {
        level == 0 ? '消す' : level.to_s
      }
      level -= 1
    end
    nil
  end

  def on_dot_art_editor_toggle(_event)
    @dot_art_editor_on = !@dot_art_editor_on
    if @dot_art_editor_on
      SimApp.stop_task
      AdventureBoard.speaker.stop
      @dot_levels ||= Array.new(WIDTH * HEIGHT, 0)
      @dot_pen ||= BRIGHTEST
      show_dot_art
      @dot_art_editor_text_stale = true
    end
    refresh
    nil
  end

  def on_dot_art_editor_click(event)
    scale = BoardView::PANEL_PX / event.target[:clientWidth].to_f
    x = DotArtEditor.dot_at(event[:offsetX].to_f * scale)
    y = DotArtEditor.dot_at(event[:offsetY].to_f * scale)
    # A click on the canvas's edge, outside the 16 x 16 dots.
    return nil if x < 1 || WIDTH < x || y < 1 || HEIGHT < y
    i = (y - 1) * WIDTH + (x - 1)
    @dot_levels[i] = if @dot_levels[i] == @dot_pen
      0
    else
      @dot_pen
    end
    show_dot_art
    @dot_art_editor_text_stale = true
    if @dot_art_editor_copied
      @dot_art_editor_copied = false
      refresh
    end
    nil
  end

  def on_dot_art_editor_pen(event)
    @dot_pen = event.target.getAttribute('data-level').to_s.to_i
    refresh
    nil
  end

  def on_dot_art_editor_clear(_event)
    @dot_levels = Array.new(WIDTH * HEIGHT, 0)
    show_dot_art
    @dot_art_editor_text_stale = true
    @dot_art_editor_copied = false
    refresh
    nil
  end

  def on_dot_art_editor_copy(_event)
    JS.global[:navigator][:clipboard].writeText(DotArtEditor.text(@dot_levels))
    @dot_art_editor_copied = true
    refresh
    nil
  end

  def show_dot_art
    matrix = AdventureBoard.matrix
    matrix.clear
    i = 0
    while i < @dot_levels.size
      level = @dot_levels[i]
      matrix.set(i % WIDTH + 1, i / WIDTH + 1, DotArtEditor.brightness(level)) unless level == 0
      i += 1
    end
    matrix.show
  end

  # On the heartbeat: the text box appears a render after the toggle, so it
  # is filled whenever it is there and behind.
  def draw_dot_art_editor
    return nil unless @dot_art_editor_text_stale
    box = refs[:dot_art_editor_text]
    return nil unless box
    box[:value] = DotArtEditor.text(@dot_levels)
    @dot_art_editor_text_stale = false
    nil
  end
end
