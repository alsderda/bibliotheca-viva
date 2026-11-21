class_name TabStrip
extends HBoxContainer
## A row of page tabs that scrolls sideways when it doesn't fit, and shows that
## it does: the clipped edge fades out and a chevron button floats over that
## edge to page the row along. A mouse can't drag a ScrollContainer, and on a
## touch screen the arrow is what tells the user there are more tabs to swipe to.
##
## Layout: a ScrollContainer (taking the strip's full width) of the tab buttons,
## with an overlay on top carrying the edge fades and the chevrons. Each chevron
## is shown only while there is more row hidden on its side.
## Its minimum width stays small, so the strip shrinks with the window instead of
## pushing the rest of the top bar off screen.

## The ScrollContainer's horizontal scroll, in pixels. Set it before the strip
## enters the tree to restore where the row was scrolled to after a rebuild.
var scroll_offset: float:
	get:
		if _settled:
			return float(_scroll.scroll_horizontal)
		return _pending
	set(value):
		_pending = maxf(0.0, value)
		if _settled:
			_scroll.scroll_horizontal = clampi(int(round(_pending)), 0, int(round(_max_scroll())))
			_refresh_indicators()

## The chevron buttons float over the row's ends, so each fade is opaque under
## the arrow glyph (letters showing through it look broken), then ramps to
## transparent just inside it: the next tab reads up to the arrow and fades
## out behind it.
const CHEV_SIZE := 28.0
## Where the 20 px arrow glyph, centred in the button, ends.
const CHEV_GLYPH_END := 24.0
const FADE_RAMP := 22.0
const FADE_W := CHEV_GLYPH_END + FADE_RAMP

var _buttons: Array[Button] = []
var _on_select: Callable
var _selected := 0
var _phone := false
var _pending := 0.0
var _revealed := false
var _settled := false
var _scroll: ScrollContainer
var _row: HBoxContainer
var _left: Button
var _right: Button
var _fade_l: TextureRect
var _fade_r: TextureRect
var _page_tween: Tween


## names: tab labels. selected: index of the pressed tab.
## on_select: called with the tab's index when the user picks one.
## phone: the compact (phone/narrow window) look: a 48 px tall row of
## 56 x 48 tap targets with no gap, padded with UiTheme.tab_styles(Vector4(12, 12, 12, 12)).
## Otherwise the desktop look: "TabButton" buttons 22 px apart, no extra padding.
func _init(names: PackedStringArray, selected: int, on_select: Callable, phone := false) -> void:
	_phone = phone
	_on_select = on_select
	_selected = selected
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("separation", 0)
	# A container, not a plain Control, so the row's height reaches the strip's
	# minimum size (a plain Control reports none, and the row would collapse).
	var clip := MarginContainer.new()
	clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(clip)
	_scroll = ScrollContainer.new()
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	var row := _row_of(names, phone)
	# A ScrollContainer only stretches a child that asks to expand; without it
	# the tabs sit short of the bar and their underline floats above its edge.
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(row)
	clip.add_child(_scroll)
	# The fades and chevrons float over the row's edges, so they live beside the
	# ScrollContainer (a child of it would join the scrolled content).
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(overlay)
	_fade_l = _make_fade(false, FADE_W, CHEV_GLYPH_END)
	_fade_r = _make_fade(true, FADE_W, CHEV_GLYPH_END)
	overlay.add_child(_fade_l)
	overlay.add_child(_fade_r)
	# The chevrons sit on top of the fades, anchored to the overlay's edges, so
	# they take no room from the row. A Button stops the clicks it covers while
	# the ignored overlay lets the rest through to the tabs beside it.
	_left = UI.icon_button("chev_left", "Scroll tabs left", _page_left)
	_right = UI.icon_button("chev_right", "Scroll tabs right", _page_right)
	for c in [_left, _right]:
		c.visible = false
		c.gui_input.connect(_on_chev_wheel)
		overlay.add_child(c)
	_anchor_chev(_left, false)
	_anchor_chev(_right, true)


func _row_of(names: PackedStringArray, phone: bool) -> HBoxContainer:
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 0 if phone else 22)
	_row.mouse_filter = Control.MOUSE_FILTER_PASS
	var group := ButtonGroup.new()
	for i in names.size():
		var b := Button.new()
		b.text = names[i]
		b.theme_type_variation = "TabButton"
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		# Lets wheel events through to the ScrollContainer, which scrolls
		# sideways and consumes them only while the row overflows.
		b.mouse_filter = Control.MOUSE_FILTER_PASS
		b.button_pressed = i == _selected
		b.pressed.connect(_pick.bind(i))
		_row.add_child(b)
		_buttons.append(b)
	if phone:
		# On phones the padding is the space between tabs, so each one is
		# easy to tap. Every state gets the same padding: a button is sized
		# for its normal box, so a wider selected box would clip its label.
		_row.add_theme_constant_override("separation", 0)
		var styles := UiTheme.tab_styles(Vector4(12, 12, 12, 12))
		for b in _buttons:
			b.custom_minimum_size = Vector2(56, 48)
			for state in styles:
				b.add_theme_stylebox_override(state, styles[state])
	return _row


## The top bar's panel is UiTheme.BG, so a fade to that color melts the cut-off
## tab into the bar instead of ending in a hard edge. With a chevron the fade
## stays opaque for hard_px (under the arrow's outer half) and then ramps to
## clear; without one it ramps from the edge.
static func _make_fade(mirrored: bool, width_px: float, hard_px := 0.0) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, UiTheme.BG)
	g.set_color(1, Color(UiTheme.BG, 0.0))
	if hard_px > 0.0:
		g.add_point(hard_px / width_px, UiTheme.BG)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_LINEAR
	t.fill_from = Vector2(1.0, 0.5) if mirrored else Vector2(0.0, 0.5)
	t.fill_to = Vector2(0.0, 0.5) if mirrored else Vector2(1.0, 0.5)
	t.width = int(width_px)
	t.height = 2
	var f := TextureRect.new()
	f.texture = t
	f.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	f.stretch_mode = TextureRect.STRETCH_SCALE
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.anchor_top = 0.0
	f.anchor_bottom = 1.0
	f.offset_top = 0.0
	f.offset_bottom = 0.0
	# The strip sits on the top bar's bottom border, which the fade would hide
	# along with the cut-off tab's underline; draw the border back over both.
	var line := ColorRect.new()
	line.color = UiTheme.BORDER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.anchor_top = 1.0
	line.anchor_right = 1.0
	line.anchor_bottom = 1.0
	line.offset_top = -1.0
	f.add_child(line)
	if mirrored:
		f.anchor_left = 1.0
		f.anchor_right = 1.0
		f.offset_left = -width_px
		f.offset_right = 0.0
	else:
		f.offset_left = 0.0
		f.offset_right = width_px
	f.visible = false
	return f


## Pins a chevron over the overlay's edge, centred on the row's height and flush
## with the strip's side, so tabs stay visible right up to the arrow.
static func _anchor_chev(c: Button, right_side: bool) -> void:
	c.anchor_top = 0.5
	c.anchor_bottom = 0.5
	c.offset_top = -CHEV_SIZE / 2.0
	c.offset_bottom = CHEV_SIZE / 2.0
	if right_side:
		c.anchor_left = 1.0
		c.anchor_right = 1.0
		c.offset_left = -CHEV_SIZE
		c.offset_right = 0.0
	else:
		c.anchor_left = 0.0
		c.anchor_right = 0.0
		c.offset_left = 0.0
		c.offset_right = CHEV_SIZE


func _ready() -> void:
	_scroll.get_h_scroll_bar().value_changed.connect(_on_scroll_changed)
	_scroll.resized.connect(_on_scroll_resized)
	_row.resized.connect(_refresh_indicators)
	_row.sort_children.connect(_refresh_indicators)
	_maybe_reveal.call_deferred()


## The tab buttons, in order (for tests).
func buttons() -> Array[Button]:
	return _buttons


## How much wider the row of tabs is than the room it has, in pixels; negative
## when it fits with that much to spare. The top bar uses it to decide whether
## the page's search field must shrink to an icon (> 0) or may grow back
## (<= -its extra width). It must not depend on the chevrons or the scroll.
func overflow() -> float:
	if not is_instance_valid(_row) or not is_instance_valid(_scroll):
		return 0.0
	return _row.get_combined_minimum_size().x - _scroll.size.x


func _pick(index: int) -> void:
	_on_select.call(index)


func _page_left() -> void:
	_page(-1)


func _page_right() -> void:
	_page(1)


func _page(dir: int) -> void:
	if not is_inside_tree():
		return
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	# Move by what shows between the two edge overlays, so the tab that was
	# fading behind the arrow ends up fully readable; always move a little.
	var step := maxf(_scroll.size.x - 2.0 * FADE_W, 40.0)
	var target := clampf(float(_scroll.scroll_horizontal) + step * float(dir), 0.0, _max_scroll())
	_page_tween = create_tween()
	_page_tween.tween_property(_scroll, "scroll_horizontal", int(round(target)), 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## A chevron is only shown while the row overflows, so a wheel over one may
## always page the row; it never reaches the row beneath it.
func _on_chev_wheel(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
				or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT):
			accept_event()
			_page(1 if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN or mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT else -1)


func _on_scroll_changed(_value: float) -> void:
	if _settled:
		_pending = float(_scroll.scroll_horizontal)
	_refresh_indicators()


func _on_scroll_resized() -> void:
	_maybe_reveal()
	_refresh_indicators()


func _maybe_reveal() -> void:
	if _revealed or not is_inside_tree() or _scroll.size.x <= 0.0:
		return
	_revealed = true
	_settle.call_deferred(3)


## When the strip first gets its width, the scroll range and then the buttons'
## positions are each worked out in their own deferred layout pass, and a
## scroll set before them is clamped to the old range. So this waits behind
## them; the hops still run before the frame is drawn, so the row never shows
## at the wrong place first.
func _settle(hops: int) -> void:
	if hops > 0:
		_settle.call_deferred(hops - 1)
		return
	if not is_inside_tree():
		return
	_settled = true
	var maxs := _max_scroll()
	var target := clampf(_pending, 0.0, maxs)
	if _selected >= 0 and _selected < _buttons.size():
		var b := _buttons[_selected]
		var view := _scroll.size.x
		# A rebuild (filtering, picking a tab) restores the old scroll; keep it
		# when the picked tab already shows clear of both edge overlays.
		var lz := FADE_W if target > 0.0 else 0.0
		var rz := FADE_W if target < maxs - 0.5 else 0.0
		var clear := b.position.x >= target + lz and b.position.x + b.size.x <= target + view - rz
		if not clear:
			# Otherwise centre it (clamped to the scroll range), so parts of
			# its neighbours show on both sides.
			target = clampf(b.position.x + b.size.x * 0.5 - view * 0.5, 0.0, maxs)
	_scroll.scroll_horizontal = int(round(target))
	_pending = target
	_refresh_indicators()


## The chevrons and fades float over the row without taking layout space, so
## showing or hiding one can't change the overflow that showed it; plain visible
## can't loop.
func _refresh_indicators() -> void:
	if not is_instance_valid(_scroll):
		return
	var max_scroll := _max_scroll()
	var over := max_scroll > 1.0
	var left := over and _scroll.scroll_horizontal > 0
	var right := over and float(_scroll.scroll_horizontal) < max_scroll - 0.5
	_left.visible = left
	_right.visible = right
	_fade_l.visible = left
	_fade_r.visible = right


func _max_scroll() -> float:
	if not is_instance_valid(_scroll):
		return 0.0
	var bar := _scroll.get_h_scroll_bar()
	return maxf(0.0, bar.max_value - bar.page)
