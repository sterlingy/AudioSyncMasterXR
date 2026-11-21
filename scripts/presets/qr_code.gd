class_name QrCode
extends RefCounted
## QR Code generator (ISO/IEC 18004, model 2), byte mode, versions 1-40,
## our own implementation. Used to show preset share codes as scannable
## images. encode() picks the smallest version that fits and the mask with
## the lowest penalty; to_image() draws it with a quiet zone.

enum Ecc { L, M, Q, H }

const ECC_FORMAT_BITS := [1, 0, 3, 2] # L, M, Q, H as stored in the format field

const ECC_CODEWORDS_PER_BLOCK := [
	[-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
	[-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]
const NUM_BLOCKS := [
	[-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
	[-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
	[-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
	[-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]

var version := 1
var size := 21
var ecc := Ecc.M
var mask := 0
var modules := PackedByteArray() # size*size, 1 = dark
var _is_function := PackedByteArray()


# ---- Capacity

static func raw_data_modules(ver: int) -> int:
	var result := (16 * ver + 128) * ver + 64
	if ver >= 2:
		var num_align := ver / 7 + 2
		result -= (25 * num_align - 10) * num_align - 55
		if ver >= 7:
			result -= 36
	return result


static func data_codewords(ver: int, level: int) -> int:
	return raw_data_modules(ver) / 8 - ECC_CODEWORDS_PER_BLOCK[level][ver] * NUM_BLOCKS[level][ver]


## Largest byte payload for a version and level.
static func byte_capacity(ver: int, level: int) -> int:
	var bits := data_codewords(ver, level) * 8 - 4 - (8 if ver < 10 else 16)
	return bits / 8


# ---- Encoding

## Encodes bytes; returns null if they don't fit in version 40.
static func encode(data: PackedByteArray, level := Ecc.M, min_version := 1) -> QrCode:
	var ver := maxi(1, min_version)
	while ver <= 40 and byte_capacity(ver, level) < data.size():
		ver += 1
	if ver > 40:
		return null
	# Use a stronger level if it still fits in the same version.
	for better in [Ecc.M, Ecc.Q, Ecc.H]:
		if better > level and byte_capacity(ver, better) >= data.size():
			level = better
	var bits := _BitBuffer.new()
	bits.append(4, 4) # byte mode
	bits.append(data.size(), 8 if ver < 10 else 16)
	for b in data:
		bits.append(b, 8)
	var cap := data_codewords(ver, level) * 8
	bits.append(0, mini(4, cap - bits.length))
	bits.append(0, (8 - bits.length % 8) % 8)
	var pad := 0xec
	while bits.length < cap:
		bits.append(pad, 8)
		pad ^= 0xec ^ 0x11
	var qr := QrCode.new()
	qr._build(ver, level, bits.to_bytes())
	return qr


static func encode_text(text: String, level := Ecc.M) -> QrCode:
	return encode(text.to_utf8_buffer(), level)


func is_dark(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < size and y < size and modules[y * size + x] == 1


func to_image(scale := 8, border := 4) -> Image:
	var px := (size + border * 2) * scale
	var img := Image.create_empty(px, px, false, Image.FORMAT_L8)
	img.fill(Color.WHITE)
	for y in size:
		for x in size:
			if modules[y * size + x] == 1:
				img.fill_rect(Rect2i((x + border) * scale, (y + border) * scale, scale, scale), Color.BLACK)
	return img


func _build(ver: int, level: int, data: PackedByteArray) -> void:
	version = ver
	ecc = level
	size = ver * 4 + 17
	modules = PackedByteArray()
	modules.resize(size * size)
	_is_function = PackedByteArray()
	_is_function.resize(size * size)
	_draw_function_patterns()
	_draw_codewords(_add_ecc_and_interleave(data))
	# Pick the mask with the lowest penalty.
	var best := 0
	var best_penalty := -1
	for m in 8:
		_apply_mask(m)
		_draw_format_bits(m)
		var p := _penalty()
		if best_penalty < 0 or p < best_penalty:
			best = m
			best_penalty = p
		_apply_mask(m) # undo (XOR)
	mask = best
	_apply_mask(best)
	_draw_format_bits(best)


func _set_function(x: int, y: int, dark: bool) -> void:
	modules[y * size + x] = 1 if dark else 0
	_is_function[y * size + x] = 1


func _draw_function_patterns() -> void:
	for i in size:
		_set_function(6, i, i % 2 == 0)
		_set_function(i, 6, i % 2 == 0)
	_draw_finder(3, 3)
	_draw_finder(size - 4, 3)
	_draw_finder(3, size - 4)
	var pos := alignment_positions(version)
	var n := pos.size()
	for i in n:
		for j in n:
			if (i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0):
				continue
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					_set_function(pos[i] + dx, pos[j] + dy, maxi(absi(dx), absi(dy)) != 1)
	_draw_format_bits(0) # reserve; real bits drawn after masking
	_draw_version()


func _draw_finder(cx: int, cy: int) -> void:
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and y >= 0 and x < size and y < size:
				var d := maxi(absi(dx), absi(dy))
				_set_function(x, y, d != 2 and d != 4)


static func alignment_positions(ver: int) -> Array:
	if ver == 1:
		return []
	var num := ver / 7 + 2
	var step := 26 if ver == 32 else int(ceilf((ver * 4 + 4) / float(num * 2 - 2))) * 2
	var result := [6]
	var p := ver * 4 + 17 - 7
	var tail := []
	for i in num - 1:
		tail.push_front(p)
		p -= step
	result.append_array(tail)
	return result


## 15-bit format field: level and mask, BCH(15,5) protected, XOR 0x5412.
static func format_bits(level: int, m: int) -> int:
	var data: int = ECC_FORMAT_BITS[level] << 3 | m
	var rem := data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	return ((data << 10) | rem) ^ 0x5412


## 18-bit version field (versions 7+), BCH(18,6).
static func version_bits(ver: int) -> int:
	var rem := ver
	for i in 12:
		rem = (rem << 1) ^ ((rem >> 11) * 0x1f25)
	return ver << 12 | rem


func _draw_format_bits(m: int) -> void:
	var bits := format_bits(ecc, m)
	for i in range(0, 6):
		_set_function(8, i, (bits >> i) & 1 == 1)
	_set_function(8, 7, (bits >> 6) & 1 == 1)
	_set_function(8, 8, (bits >> 7) & 1 == 1)
	_set_function(7, 8, (bits >> 8) & 1 == 1)
	for i in range(9, 15):
		_set_function(14 - i, 8, (bits >> i) & 1 == 1)
	for i in range(0, 8):
		_set_function(size - 1 - i, 8, (bits >> i) & 1 == 1)
	for i in range(8, 15):
		_set_function(8, size - 15 + i, (bits >> i) & 1 == 1)
	_set_function(8, size - 8, true) # always dark


func _draw_version() -> void:
	if version < 7:
		return
	var bits := version_bits(version)
	for i in 18:
		var bit := (bits >> i) & 1 == 1
		var a := size - 11 + i % 3
		var b := i / 3
		_set_function(a, b, bit)
		_set_function(b, a, bit)


func _add_ecc_and_interleave(data: PackedByteArray) -> PackedByteArray:
	var num_blocks: int = NUM_BLOCKS[ecc][version]
	var block_ecc: int = ECC_CODEWORDS_PER_BLOCK[ecc][version]
	var raw_codewords := raw_data_modules(version) / 8
	var num_short := num_blocks - raw_codewords % num_blocks
	var short_len := raw_codewords / num_blocks
	var gen := rs_generator(block_ecc)
	var blocks := []
	var k := 0
	for i in num_blocks:
		var dlen := short_len - block_ecc + (0 if i < num_short else 1)
		var dat := data.slice(k, k + dlen)
		k += dlen
		var e := rs_remainder(dat, gen)
		if i < num_short:
			dat.append(0) # placeholder so all blocks line up
		dat.append_array(e)
		blocks.append(dat)
	var result := PackedByteArray()
	var blen: int = blocks[0].size()
	for i in blen:
		for j in blocks.size():
			if i != short_len - block_ecc or j >= num_short:
				result.append(blocks[j][i])
	return result


func _draw_codewords(data: PackedByteArray) -> void:
	var i := 0
	var right := size - 1
	while right >= 1:
		if right == 6:
			right = 5
		for vert in size:
			for j in 2:
				var x := right - j
				var upward := ((right + 1) & 2) == 0
				var y := size - 1 - vert if upward else vert
				if _is_function[y * size + x] == 0 and i < data.size() * 8:
					modules[y * size + x] = (data[i >> 3] >> (7 - (i & 7))) & 1
					i += 1
		right -= 2


static func mask_bit(m: int, x: int, y: int) -> bool:
	match m:
		0: return (x + y) % 2 == 0
		1: return y % 2 == 0
		2: return x % 3 == 0
		3: return (x + y) % 3 == 0
		4: return (x / 3 + y / 2) % 2 == 0
		5: return x * y % 2 + x * y % 3 == 0
		6: return (x * y % 2 + x * y % 3) % 2 == 0
		_: return ((x + y) % 2 + x * y % 3) % 2 == 0


func _apply_mask(m: int) -> void:
	for y in size:
		for x in size:
			if _is_function[y * size + x] == 0 and mask_bit(m, x, y):
				modules[y * size + x] ^= 1


func _penalty() -> int:
	var result := 0
	# Runs of 5+ same-colour modules in rows and columns, and finder-like patterns.
	for horiz in [true, false]:
		for a in size:
			var run := 0
			var last := -1
			var window := 0
			for b in size:
				var v: int = modules[a * size + b] if horiz else modules[b * size + a]
				if v == last:
					run += 1
					if run == 5:
						result += 3
					elif run > 5:
						result += 1
				else:
					run = 1
					last = v
				window = ((window << 1) | v) & 0x7ff
				if b >= 10 and (window == 0x05d or window == 0x5d0):
					result += 40
	# 2x2 blocks.
	for y in size - 1:
		for x in size - 1:
			var c := modules[y * size + x]
			if c == modules[y * size + x + 1] and c == modules[(y + 1) * size + x] and c == modules[(y + 1) * size + x + 1]:
				result += 3
	# Balance of dark modules.
	var dark := 0
	for v in modules:
		dark += v
	var total := size * size
	var kk := int(ceilf(absf(dark * 20 - total * 10) / float(total))) - 1
	result += maxi(kk, 0) * 10
	return result


# ---- Reed-Solomon over GF(256), polynomial 0x11d

static func gf_mul(a: int, b: int) -> int:
	var z := 0
	for i in range(7, -1, -1):
		z = (z << 1) ^ ((z >> 7) * 0x11d)
		z ^= ((b >> i) & 1) * a
	return z & 0xff


static func rs_generator(degree: int) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(degree)
	result[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			result[j] = gf_mul(result[j], root)
			if j + 1 < degree:
				result[j] ^= result[j + 1]
		root = gf_mul(root, 0x02)
	return result


static func rs_remainder(data: PackedByteArray, gen: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(gen.size())
	for b in data:
		var factor := b ^ result[0]
		for i in result.size() - 1:
			result[i] = result[i + 1]
		result[result.size() - 1] = 0
		for i in result.size():
			result[i] ^= gf_mul(gen[i], factor)
	return result


class _BitBuffer:
	var bits: Array[int] = []
	var length: int:
		get:
			return bits.size()

	func append(value: int, count: int) -> void:
		for i in range(count - 1, -1, -1):
			bits.append((value >> i) & 1)

	func to_bytes() -> PackedByteArray:
		var out := PackedByteArray()
		out.resize(bits.size() / 8)
		for i in bits.size():
			out[i >> 3] |= bits[i] << (7 - (i & 7))
		return out
