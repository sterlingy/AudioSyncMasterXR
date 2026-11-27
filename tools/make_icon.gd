extends SceneTree
## Renders the app icon PNGs from assets/icon/*.svg.
##   godot --headless --path . -s res://tools/make_icon.gd
## icon.png (project/window icon), icon_192.png (Android launcher), and the
## Android adaptive layers at 432x432.

const OUT := {
	"icon.svg": [["icon.png", 1024], ["icon_192.png", 192]],
	"icon_foreground.svg": [["icon_foreground_432.png", 432]],
	"icon_background.svg": [["icon_background_432.png", 432]],
	"icon_monochrome.svg": [["icon_monochrome_432.png", 432]],
}


func _init() -> void:
	var dir := ProjectSettings.globalize_path("res://assets/icon/")
	for src in OUT:
		var svg := FileAccess.get_file_as_string(dir + src)
		for job in OUT[src]:
			var img := Image.new()
			var err := img.load_svg_from_string(svg, float(job[1]) / 1024.0)
			if err != OK:
				push_error("Can't render %s" % src)
				continue
			img.save_png(dir + job[0])
			print("%s -> %s (%dx%d)" % [src, job[0], img.get_width(), img.get_height()])
	_write_ico(FileAccess.get_file_as_string(dir + "icon.svg"), dir + "icon.ico")
	quit()


## Windows icon: an .ico holding PNG images (Vista and later read these).
func _write_ico(svg: String, path: String) -> void:
	var sizes := [16, 24, 32, 48, 64, 128, 256]
	var pngs: Array[PackedByteArray] = []
	for s in sizes:
		var img := Image.new()
		img.load_svg_from_string(svg, s / 1024.0)
		pngs.append(img.save_png_to_buffer())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_16(0); f.store_16(1); f.store_16(sizes.size()) # header: reserved, type 1 = icon, count
	var offset := 6 + 16 * sizes.size()
	for i in sizes.size():
		var s: int = sizes[i]
		f.store_8(0 if s == 256 else s); f.store_8(0 if s == 256 else s) # width, height (0 = 256)
		f.store_8(0); f.store_8(0) # palette, reserved
		f.store_16(1); f.store_16(32) # planes, bits per pixel
		f.store_32(pngs[i].size()); f.store_32(offset)
		offset += pngs[i].size()
	for p in pngs:
		f.store_buffer(p)
	print("icon.svg -> icon.ico (%s)" % ", ".join(sizes.map(func(s): return str(s))))
