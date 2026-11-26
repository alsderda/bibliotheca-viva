class_name TopBarFit
extends RefCounted
## Fits the top bar's first row to the Android camera hole and the system bars:
## keeps the safe-area insets and hole rectangles, and splits the row so its
## buttons sit beside a hole instead of under it.

const TOP_ROW_HEIGHT := 60.0
const HOLE_PAD := 8.0  # space kept between the camera hole and the buttons beside it
var _main  # the app's main Control, whose top bar this fits (untyped: it has no class_name)
## Screen edges covered by the camera hole or system bars, in UI units (x left,
## y top, z right, w bottom). The background still runs under them; controls stay out.
var _insets := Vector4.ZERO
var _cutouts: Array[Rect2] = []  # camera holes, in UI units
var _bar_span := Vector2(-1, -1)  # top bar x and width the camera-hole fit was made for


func _init(main) -> void:
	_main = main


# --- safe area (Android camera hole and system bars) -------------------------

func update_safe_area(force := false) -> void:
	var insets := Vector4.ZERO
	var cutouts: Array[Rect2] = []
	var s: float = _main.get_window().content_scale_factor
	# On desktops the "safe area" is the screen minus the taskbar, not the window's.
	if OS.has_feature("android"):
		var win := Vector2(DisplayServer.window_get_size())
		var safe := Rect2(DisplayServer.get_display_safe_area())
		insets = Vector4(safe.position.x, safe.position.y, win.x - safe.end.x, win.y - safe.end.y) / s
		for r in DisplayServer.get_display_cutouts():
			cutouts.append(Rect2(r.position / s, r.size / s))
	# Desktop testing: --fake-cutout=x,y,w,h (UI units) acts like a camera hole there.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fake-cutout="):
			var v := arg.get_slice("=", 1).split_floats(",")
			if v.size() == 4:
				cutouts = [Rect2(v[0], v[1], v[2], v[3])]
				insets.y = maxf(insets.y, v[1] + v[3])
	insets = insets.max(Vector4.ZERO)
	if not force and insets.is_equal_approx(_insets) and cutouts == _cutouts:
		return
	_insets = insets
	_cutouts = cutouts
	_main._root.offset_left = insets.x
	_main._root.offset_right = -insets.z
	_main._root.offset_bottom = -insets.w
	_main._sidebar_style.content_margin_top = 16 + insets.y
	_main._toast_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_main._toast_box.position -= Vector2(24 + insets.z, 24 + insets.w)
	_bar_span = Vector2(-1, -1)
	if not force:
		_main._rebuild_topbar()


## Camera holes at the top edge of the screen.
func top_holes() -> Array[Rect2]:
	var holes: Array[Rect2] = []
	for c in _cutouts:
		if c.position.y < 48 and c.size.y > 0:  # punch holes may sit a little below the edge
			holes.append(c)
	return holes


func on_topbar_moved() -> void:
	if _main.rail_active() or top_holes().is_empty():
		return
	if Vector2(_main._topbar.global_position.x, _main._topbar.size.x) != _bar_span:
		_main._rebuild_topbar.call_deferred()


## Puts the top bar's first row at the very top of the screen, with its buttons
## split around the camera hole, or below the hole when they don't fit beside it.
## The title then gets its own full-width line under the buttons, unless
## `title_up` and all of it fits beside the hole.
func place_top_row(row: HBoxContainer, title: Control, title_up := false) -> void:
	var style: StyleBoxFlat = _main._topbar.get_theme_stylebox("panel") as StyleBoxFlat
	var holes := top_holes()
	var depth := 0.0
	for h in holes:
		depth = maxf(depth, h.end.y)
	# The safe area's top is often deeper than the hole itself (Android makes it
	# the status bar's height), but the app runs fullscreen, so only the hole matters.
	if holes.is_empty() or not _split_row(row, title, holes, style, title_up):
		style.content_margin_top = _insets.y
	else:
		style.content_margin_top = maxf(0.0, depth - TOP_ROW_HEIGHT)


func _split_row(row: HBoxContainer, title: Control, holes: Array[Rect2], style: StyleBoxFlat, title_up: bool) -> bool:
	_bar_span = Vector2(_main._topbar.global_position.x, _main._topbar.size.x)
	var row_x := _bar_span.x + style.content_margin_left
	var row_w := _bar_span.y - style.content_margin_left - style.content_margin_right
	if row_w <= 0:
		return false  # not laid out yet; on_topbar_moved comes back once it is
	var x0 := INF
	var x1 := -INF
	for h in holes:
		x0 = minf(x0, h.position.x - row_x - HOLE_PAD)
		x1 = maxf(x1, h.end.x - row_x + HOLE_PAD)
	if x1 <= 0 or x0 >= row_w:
		return true  # the hole is beside the row, not over it
	x0 = maxf(x0, 0.0)
	x1 = minf(x1, row_w)

	var items: Array = row.get_children()
	var sep := float(row.get_theme_constant("separation"))
	var slot := items.find(title)
	# The title may stay in the row when all of it fits beside the hole.
	var best := -1
	if slot >= 0 and title_up:
		var full := _full_width(title)
		var old_min: float = title.custom_minimum_size.x
		title.custom_minimum_size.x = full
		best = _hole_slot(items, sep, x0, row_w - x1, slot + 1)
		title.custom_minimum_size.x = old_min
		if best > slot:  # title on the menu button's side of the hole
			title.custom_minimum_size.x = full
		else:
			best = -1
	if best < 0:
		# Otherwise only the buttons go up there and the title gets its own line.
		# Empty space takes its place, so the buttons keep to the ends of the row.
		if slot >= 0:
			items[slot] = UI.spacer()
		best = _hole_slot(items, sep, x0, row_w - x1, maxi(slot, 0))
		if best < 0:
			if slot >= 0:
				items[slot].free()
			return false
		if title:
			_title_below(row, title)

	var left_box := UI.hbox(int(sep))
	left_box.custom_minimum_size.x = x0
	var right_box := UI.hbox(int(sep))
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var left_fills := false
	var right_fills := false
	for i in items.size():
		var c: Control = items[i]
		if c.get_parent() == row:
			row.remove_child(c)
		var fills := (c.size_flags_horizontal & Control.SIZE_EXPAND) != 0
		if i < best:
			left_box.add_child(c)
			left_fills = left_fills or fills
		else:
			right_box.add_child(c)
			right_fills = right_fills or fills
	if not left_fills:
		left_box.add_child(UI.spacer())
	if not right_fills:
		var sp := UI.spacer()
		right_box.add_child(sp)
		right_box.move_child(sp, 0)  # keeps the actions at the right edge
	var gap := Control.new()
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gap.custom_minimum_size.x = x1 - x0
	row.add_theme_constant_override("separation", 0)
	for c in [left_box, gap, right_box]:
		row.add_child(c)
	return true


## Where in `items` the hole can go so everything before it fits in `left`
## and everything after in `right`, or -1. Picks the place nearest `near`.
static func _hole_slot(items: Array, sep: float, left: float, right: float, near: int) -> int:
	var widths: Array[float] = []
	for c: Control in items:
		widths.append(c.get_combined_minimum_size().x if c.visible else -1.0)  # hidden: takes no room
	var best := -1
	for k in items.size() + 1:
		if _span(widths.slice(0, k), sep) > left or _span(widths.slice(k), sep) > right:
			continue
		if best < 0 or absi(k - near) < absi(best - near):
			best = k
	return best


## How wide the title is with none of its text cut off.
static func _full_width(title: Control) -> float:
	if title is Label:
		var font := title.get_theme_font("font")
		var size := title.get_theme_font_size("font_size")
		return ceilf(font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	return title.get_combined_minimum_size().x


## Gives the title its own full-width line under the button row.
func _title_below(row: HBoxContainer, title: Control) -> void:
	row.remove_child(title)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_stretch_ratio = 1.0
	if title is Label:
		title.custom_minimum_size.x = 0
	var line := UI.margin(title, 8, 0, 8, 4)
	_main._top_rows.add_child(line)
	_main._top_rows.move_child(line, row.get_index() + 1)


static func _span(widths: Array, sep: float) -> float:
	var shown := widths.filter(func(w): return w >= 0.0)
	if shown.is_empty():
		return 0.0
	var total := sep * (shown.size() - 1)
	for w in shown:
		total += w
	return total
