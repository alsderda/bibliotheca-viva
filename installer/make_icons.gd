extends SceneTree
## Renders the app icon SVGs into the PNG and ICO files that exports need.
## Run after changing assets/icon.svg or assets/icons/*.svg:
##   Godot --headless --path . --script installer/make_icons.gd

const ICO_SIZES := [16, 20, 24, 32, 40, 48, 64, 128, 256]


func _init() -> void:
	var ok := true
	ok = _png("res://assets/icon.svg", 192, "res://assets/icons/icon_192.png") and ok
	ok = _png("res://assets/icon.svg", 256, "res://assets/icons/icon_256.png") and ok
	ok = _png("res://assets/icon.svg", 1024, "res://assets/icons/icon_1024.png") and ok
	ok = _png("res://assets/icons/icon_foreground.svg", 432, "res://assets/icons/icon_foreground_432.png") and ok
	ok = _png("res://assets/icons/icon_background.svg", 432, "res://assets/icons/icon_background_432.png") and ok
	ok = _ico("res://assets/icon.svg", "res://assets/icons/icon.ico") and ok
	quit(0 if ok else 1)


func _render(svg_path: String, size: int) -> Image:
	var svg := FileAccess.get_file_as_string(svg_path)
	var width := float(svg.get_slice("viewBox=\"", 1).get_slice("\"", 0).split(" ")[2])
	var img := Image.new()
	if img.load_svg_from_string(svg, size / width) != OK or img.get_width() != size:
		push_error("can't render %s at %d px" % [svg_path, size])
		return null
	return img


func _png(svg_path: String, size: int, out: String) -> bool:
	var img := _render(svg_path, size)
	return img != null and img.save_png(out) == OK


# An ICO file is a small header, one directory entry per size, then the images (PNG data works since Vista).
func _ico(svg_path: String, out: String) -> bool:
	var pngs: Array[PackedByteArray] = []
	for size in ICO_SIZES:
		var img := _render(svg_path, size)
		if img == null:
			return false
		pngs.append(img.save_png_to_buffer())
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return false
	f.store_16(0)
	f.store_16(1)
	f.store_16(ICO_SIZES.size())
	var offset := 6 + 16 * ICO_SIZES.size()
	for i in ICO_SIZES.size():
		var s: int = ICO_SIZES[i]
		f.store_8(s % 256)  # 256 is written as 0
		f.store_8(s % 256)
		f.store_8(0)
		f.store_8(0)
		f.store_16(1)
		f.store_16(32)
		f.store_32(pngs[i].size())
		f.store_32(offset)
		offset += pngs[i].size()
	for png in pngs:
		f.store_buffer(png)
	f.close()
	return true
