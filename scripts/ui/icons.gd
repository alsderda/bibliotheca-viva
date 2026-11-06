class_name Icons
## Stroke icons (Lucide style, 24x24) rendered at runtime from SVG strings,
## so they stay sharp at any UI scale and can be tinted.

const PATHS := {
	"library": "<path d='M4 19.5V5a2 2 0 0 1 2-2h13v16H6.5A2.5 2.5 0 0 0 4 21.5v0A2.5 2.5 0 0 1 6.5 19H19'/><path d='M9 7h6'/>",
	"compass": "<circle cx='12' cy='12' r='9'/><path d='m15.5 8.5-2 5-5 2 2-5z'/>",
	"bell": "<path d='M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9'/><path d='M10.3 21a1.94 1.94 0 0 0 3.4 0'/>",
	"settings": "<path d='M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0'/><circle cx='16' cy='6' r='2'/><circle cx='10' cy='12' r='2'/><circle cx='18' cy='18' r='2'/>",
	"filter": "<path d='M3 5h18l-7 8.5V19l-4 2v-7.5z'/>",
	"search": "<circle cx='11' cy='11' r='7'/><path d='m20 20-3.5-3.5'/>",
	"plus": "<path d='M12 5v14M5 12h14'/>",
	"import": "<path d='M12 3v12'/><path d='m7 10 5 5 5-5'/><path d='M5 21h14'/>",
	"play": "<path d='M7 4.5v15l12-7.5z' fill='CLR'/>",
	"pause": "<rect x='6' y='5' width='4' height='14' rx='1' fill='CLR'/><rect x='14' y='5' width='4' height='14' rx='1' fill='CLR'/>",
	"skip_back": "<path d='M18 18 9 12l9-6z' fill='CLR'/><path d='M6 6v12'/>",
	"skip_fwd": "<path d='m6 18 9-6-9-6z' fill='CLR'/><path d='M18 6v12'/>",
	"stop": "<rect x='6' y='6' width='12' height='12' rx='2' fill='CLR'/>",
	"chev_left": "<path d='m15 18-6-6 6-6'/>",
	"chev_right": "<path d='m9 18 6-6-6-6'/>",
	"chev_down": "<path d='m6 9 6 6 6-6'/>",
	"arrow_left": "<path d='M19 12H5'/><path d='m12 19-7-7 7-7'/>",
	"menu": "<path d='M4 6h16M4 12h16M4 18h16'/>",
	"list": "<path d='M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01'/>",
	"info": "<circle cx='12' cy='12' r='9'/><path d='M12 16v-4M12 8h.01'/>",
	"type": "<path d='M4 7V4h16v3'/><path d='M9 20h6'/><path d='M12 4v16'/>",
	"headphones": "<path d='M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3'/>",
	"grid": "<rect x='3' y='3' width='7' height='7' rx='1'/><rect x='14' y='3' width='7' height='7' rx='1'/><rect x='3' y='14' width='7' height='7' rx='1'/><rect x='14' y='14' width='7' height='7' rx='1'/>",
	"rows": "<rect x='3' y='4' width='18' height='6' rx='1'/><rect x='3' y='14' width='18' height='6' rx='1'/>",
	"refresh": "<path d='M21 12a9 9 0 1 1-3-6.7L21 8'/><path d='M21 3v5h-5'/>",
	"external": "<path d='M15 3h6v6'/><path d='M10 14 21 3'/><path d='M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6'/>",
	"download": "<path d='M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4'/><path d='m7 10 5 5 5-5'/><path d='M12 15V3'/>",
	"check": "<path d='M20 6 9 17l-5-5'/>",
	"x": "<path d='M18 6 6 18M6 6l12 12'/>",
	"globe": "<circle cx='12' cy='12' r='9'/><path d='M3 12h18'/><path d='M12 3a14 14 0 0 1 0 18a14 14 0 0 1 0-18'/>",
	"server": "<rect x='3' y='3' width='18' height='8' rx='2'/><rect x='3' y='13' width='18' height='8' rx='2'/><path d='M7 7h.01M7 17h.01'/>",
	"volume": "<path d='M11 5 6 9H2v6h4l5 4z'/><path d='M15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14'/>",
	"link": "<path d='M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7'/><path d='M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7'/>",
	"book": "<path d='M2 4h6a4 4 0 0 1 4 4v13a3 3 0 0 0-3-3H2z'/><path d='M22 4h-6a4 4 0 0 0-4 4v13a3 3 0 0 1 3-3h7z'/>",
	"rss": "<path d='M4 11a9 9 0 0 1 9 9'/><path d='M4 4a16 16 0 0 1 16 16'/><circle cx='5' cy='19' r='1' fill='CLR'/>",
	"trash": "<path d='M3 6h18'/><path d='M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6'/><path d='M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2'/>",
	"more": "<circle cx='5' cy='12' r='1' fill='CLR'/><circle cx='12' cy='12' r='1' fill='CLR'/><circle cx='19' cy='12' r='1' fill='CLR'/>",
	"moon": "<path d='M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z'/>",
	"image": "<rect x='3' y='3' width='18' height='18' rx='2'/><circle cx='9' cy='9' r='2'/><path d='m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21'/>",
	"pencil": "<path d='M17 3a2.85 2.85 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5z'/>",
	"arrow_up": "<path d='m18 15-6-6-6 6'/>",
	"arrow_down": "<path d='m6 9 6 6 6-6'/>",
	"copy": "<rect x='8' y='8' width='13' height='13' rx='2'/><path d='M4 16V5a1 1 0 0 1 1-1h11'/>",
	"clipboard": "<rect x='8' y='2' width='8' height='4' rx='1'/><path d='M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2'/>",
	"replace": "<path d='M14 4h6v6'/><path d='M20 4 13 11'/><path d='M4 14h6v6'/><path d='m4 20 7-7'/>",
	"regex": "<path d='M17 3v10'/><path d='m12.7 5.5 8.6 5'/><path d='m12.7 10.5 8.6-5'/><rect x='3' y='15' width='6' height='6' rx='1'/>",
	"eye": "<path d='M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z'/><circle cx='12' cy='12' r='3'/>",
	"mic": "<rect x='9' y='2' width='6' height='12' rx='3'/><path d='M5 10a7 7 0 0 0 14 0'/><path d='M12 17v5'/>",
	"arrow_right": "<path d='M5 12h14'/><path d='m12 5 7 7-7 7'/>",
	"shield": "<path d='M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'/>",
	"bookmark": "<path d='m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z'/>",
	"bookmark_fill": "<path d='m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z' fill='CLR'/>",
	"sparkle": "<path d='M12 3l1.9 5.8L20 11l-6.1 2.2L12 19l-1.9-5.8L4 11l6.1-2.2z'/>",
}

static var _cache := {}


static func get_icon(name: String, color := Color.WHITE, size := 20) -> Texture2D:
	var scale := 1.0
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		scale = tree.root.content_scale_factor
	var key := "%s|%s|%d|%.2f" % [name, color.to_html(), size, scale]
	if _cache.has(key):
		return _cache[key]
	var hex := "#" + color.to_html(false)
	var body: String = PATHS.get(name, PATHS.info).replace("CLR", hex)
	var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='%s' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round' stroke-opacity='%.3f'>%s</svg>" % [hex, color.a, body]
	var img := Image.new()
	img.load_svg_from_string(svg, size / 24.0 * scale)
	var tex := ImageTexture.create_from_image(img)
	if scale != 1.0:
		tex.set_size_override(Vector2i(size, size))
	_cache[key] = tex
	return tex
