class_name ShivooQR
extends RefCounted
## QR Code Model 2 encoder, byte mode, for printing site sheets from the editor.
## A port of the encoding half of Project Nayuki's QR Code generator (MIT License,
## https://www.nayuki.io/page/qr-code-generator-library): same version choice,
## error correction boost and mask selection, so its output matches module for
## module.

enum Ecc { LOW, MEDIUM, QUARTILE, HIGH }

## Format bits for each Ecc, as the standard numbers them.
const _FORMAT_BITS: Array[int] = [1, 0, 3, 2]
const _PENALTY_N1 := 3
const _PENALTY_N2 := 3
const _PENALTY_N3 := 40
const _PENALTY_N4 := 10
const _ECC_CODEWORDS_PER_BLOCK: Array[Array] = [
	[-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
	[-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]
const _NUM_ERROR_CORRECTION_BLOCKS: Array[Array] = [
	[-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
	[-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
	[-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
	[-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]

## Modules per side.
var size := 0
var version := 0
var ecc := Ecc.MEDIUM
var mask := 0

var _modules := PackedByteArray()
var _function := PackedByteArray()


## Encode [param text] as UTF-8 in the smallest version that fits at [param min_ecc],
## raising the error correction level where that costs no extra size.
static func encode(text: String, min_ecc := Ecc.MEDIUM) -> ShivooQR:
	var data := text.to_utf8_buffer()
	var chosen := 0
	var used_bits := 0
	for v in range(1, 41):
		used_bits = 4 + (8 if v < 10 else 16) + data.size() * 8
		if used_bits <= _num_data_codewords(v, min_ecc) * 8:
			chosen = v
			break
	if chosen == 0:
		push_error("ShivooQR: %d bytes do not fit in a QR code" % data.size())
		return null
	var level := min_ecc
	for boosted in [Ecc.MEDIUM, Ecc.QUARTILE, Ecc.HIGH]:
		if boosted > level and used_bits <= _num_data_codewords(chosen, boosted) * 8:
			level = boosted
	var bits := PackedByteArray()
	_append_bits(bits, 0x4, 4)
	_append_bits(bits, data.size(), 8 if chosen < 10 else 16)
	for b in data:
		_append_bits(bits, b, 8)
	var capacity := _num_data_codewords(chosen, level) * 8
	_append_bits(bits, 0, mini(4, capacity - bits.size()))
	_append_bits(bits, 0, posmod(-bits.size(), 8))
	var pad := 0xEC
	while bits.size() < capacity:
		_append_bits(bits, pad, 8)
		pad = 0x11 if pad == 0xEC else 0xEC
	var codewords := PackedByteArray()
	codewords.resize(bits.size() / 8)
	for i in bits.size():
		codewords[i >> 3] |= bits[i] << (7 - (i & 7))
	var qr := ShivooQR.new()
	qr._build(chosen, level, codewords)
	return qr


## Whether the module at [param x], [param y] (0, 0 top left) is dark.
func is_dark(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < size and y < size and _modules[y * size + x] != 0


## The code as black on white, [param scale] pixels per module, with a
## [param quiet] module white border.
func to_image(scale: int, quiet := 4) -> Image:
	var side := (size + quiet * 2) * scale
	var image := Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	for y in size:
		for x in size:
			if is_dark(x, y):
				image.fill_rect(Rect2i((x + quiet) * scale, (y + quiet) * scale, scale, scale), Color.BLACK)
	return image


func _build(p_version: int, p_ecc: Ecc, codewords: PackedByteArray) -> void:
	version = p_version
	ecc = p_ecc
	size = version * 4 + 17
	_modules.resize(size * size)
	_function.resize(size * size)
	_draw_function_patterns()
	_draw_codewords(_add_ecc_and_interleave(codewords))
	var best := 0
	var lowest := 1 << 32
	for m in 8:
		_apply_mask(m)
		_draw_format_bits(m)
		var penalty := _penalty_score()
		if penalty < lowest:
			best = m
			lowest = penalty
		_apply_mask(m)
	mask = best
	_apply_mask(mask)
	_draw_format_bits(mask)


func _set_function(x: int, y: int, dark: bool) -> void:
	_modules[y * size + x] = 1 if dark else 0
	_function[y * size + x] = 1


func _draw_function_patterns() -> void:
	for i in size:
		_set_function(6, i, i % 2 == 0)
		_set_function(i, 6, i % 2 == 0)
	_draw_finder(3, 3)
	_draw_finder(size - 4, 3)
	_draw_finder(3, size - 4)
	var positions := _alignment_positions()
	var last := positions.size() - 1
	for i in positions.size():
		for j in positions.size():
			if (i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0):
				continue
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					_set_function(positions[i] + dx, positions[j] + dy, maxi(absi(dx), absi(dy)) != 1)
	_draw_format_bits(0)
	_draw_version()


func _draw_finder(cx: int, cy: int) -> void:
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and y >= 0 and x < size and y < size:
				var d := maxi(absi(dx), absi(dy))
				_set_function(x, y, d != 2 and d != 4)


func _draw_format_bits(m: int) -> void:
	var data := _FORMAT_BITS[ecc] << 3 | m
	var rem := data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	var bits := (data << 10 | rem) ^ 0x5412
	for i in 6:
		_set_function(8, i, _bit(bits, i))
	_set_function(8, 7, _bit(bits, 6))
	_set_function(8, 8, _bit(bits, 7))
	_set_function(7, 8, _bit(bits, 8))
	for i in range(9, 15):
		_set_function(14 - i, 8, _bit(bits, i))
	for i in 8:
		_set_function(size - 1 - i, 8, _bit(bits, i))
	for i in range(8, 15):
		_set_function(8, size - 15 + i, _bit(bits, i))
	_set_function(8, size - 8, true)


func _draw_version() -> void:
	if version < 7:
		return
	var rem := version
	for i in 12:
		rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
	var bits := version << 12 | rem
	for i in 18:
		var a := size - 11 + i % 3
		var b := i / 3
		_set_function(a, b, _bit(bits, i))
		_set_function(b, a, _bit(bits, i))


func _alignment_positions() -> Array[int]:
	var result: Array[int] = []
	if version == 1:
		return result
	var count := version / 7 + 2
	var step := (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
	for i in count - 1:
		result.push_front(size - 7 - i * step)
	result.push_front(6)
	return result


func _add_ecc_and_interleave(data: PackedByteArray) -> PackedByteArray:
	var blocks_count: int = _NUM_ERROR_CORRECTION_BLOCKS[ecc][version]
	var ecc_len: int = _ECC_CODEWORDS_PER_BLOCK[ecc][version]
	var raw := _num_raw_data_modules(version) / 8
	var short_count := blocks_count - raw % blocks_count
	var short_len := raw / blocks_count
	var divisor := _rs_divisor(ecc_len)
	var blocks: Array[PackedByteArray] = []
	var k := 0
	for i in blocks_count:
		var length := short_len - ecc_len + (0 if i < short_count else 1)
		var block := data.slice(k, k + length)
		k += length
		var remainder := _rs_remainder(block, divisor)
		if i < short_count:
			block.append(0)
		block.append_array(remainder)
		blocks.append(block)
	var result := PackedByteArray()
	for i in blocks[0].size():
		for j in blocks.size():
			if i != short_len - ecc_len or j >= short_count:
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
				if _function[y * size + x] == 0 and i < data.size() * 8:
					_modules[y * size + x] = 1 if _bit(data[i >> 3], 7 - (i & 7)) else 0
					i += 1
		right -= 2


func _apply_mask(m: int) -> void:
	for y in size:
		for x in size:
			var invert := false
			match m:
				0: invert = (x + y) % 2 == 0
				1: invert = y % 2 == 0
				2: invert = x % 3 == 0
				3: invert = (x + y) % 3 == 0
				4: invert = (x / 3 + y / 2) % 2 == 0
				5: invert = x * y % 2 + x * y % 3 == 0
				6: invert = (x * y % 2 + x * y % 3) % 2 == 0
				7: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
			if invert and _function[y * size + x] == 0:
				_modules[y * size + x] ^= 1


func _penalty_score() -> int:
	var result := 0
	for horizontal in [true, false]:
		for a in size:
			var run_color := 0
			var run := 0
			var history: Array[int] = [0, 0, 0, 0, 0, 0, 0]
			for b in size:
				var color := _modules[a * size + b] if horizontal else _modules[b * size + a]
				if color == run_color:
					run += 1
					if run == 5:
						result += _PENALTY_N1
					elif run > 5:
						result += 1
				else:
					_history_add(run, history)
					if run_color == 0:
						result += _finder_count(history) * _PENALTY_N3
					run_color = color
					run = 1
			result += _finder_terminate(run_color, run, history) * _PENALTY_N3
	for y in size - 1:
		for x in size - 1:
			var c := _modules[y * size + x]
			if c == _modules[y * size + x + 1] and c == _modules[(y + 1) * size + x] \
					and c == _modules[(y + 1) * size + x + 1]:
				result += _PENALTY_N2
	var dark := 0
	for c in _modules:
		dark += c
	var total := size * size
	var k := (absi(dark * 20 - total * 10) + total - 1) / total - 1
	result += k * _PENALTY_N4
	return result


func _finder_count(history: Array[int]) -> int:
	var n := history[1]
	var core := n > 0 and history[2] == n and history[4] == n and history[5] == n and history[3] == n * 3
	return (1 if core and history[0] >= n * 4 and history[6] >= n else 0) \
		+ (1 if core and history[6] >= n * 4 and history[0] >= n else 0)


func _finder_terminate(run_color: int, run: int, history: Array[int]) -> int:
	if run_color != 0:
		_history_add(run, history)
		run = 0
	run += size
	_history_add(run, history)
	return _finder_count(history)


func _history_add(run: int, history: Array[int]) -> void:
	if history[0] == 0:
		run += size
	history.push_front(run)
	history.pop_back()


static func _num_raw_data_modules(v: int) -> int:
	var result := (16 * v + 128) * v + 64
	if v >= 2:
		var count := v / 7 + 2
		result -= (25 * count - 10) * count - 55
		if v >= 7:
			result -= 36
	return result


static func _num_data_codewords(v: int, level: Ecc) -> int:
	return _num_raw_data_modules(v) / 8 - _ECC_CODEWORDS_PER_BLOCK[level][v] * _NUM_ERROR_CORRECTION_BLOCKS[level][v]


static func _rs_divisor(degree: int) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(degree)
	result[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			result[j] = _rs_multiply(result[j], root)
			if j + 1 < degree:
				result[j] ^= result[j + 1]
		root = _rs_multiply(root, 0x02)
	return result


static func _rs_remainder(data: PackedByteArray, divisor: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(divisor.size())
	for b in data:
		var factor := b ^ result[0]
		result.remove_at(0)
		result.append(0)
		for i in divisor.size():
			result[i] ^= _rs_multiply(divisor[i], factor)
	return result


static func _rs_multiply(x: int, y: int) -> int:
	var z := 0
	for i in range(7, -1, -1):
		z = (z << 1) ^ ((z >> 7) * 0x11D)
		z ^= ((y >> i) & 1) * x
	return z


static func _append_bits(bits: PackedByteArray, value: int, count: int) -> void:
	for i in range(count - 1, -1, -1):
		bits.append((value >> i) & 1)


static func _bit(value: int, i: int) -> bool:
	return (value >> i) & 1 != 0
