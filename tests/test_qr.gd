extends GutTest
## QR encoder: published reference values, plus a decoder that reads the
## matrix back (format, unmask, zigzag, de-interleave, Reed-Solomon check).


func test_reference_values() -> void:
	# Format fields from the standard's table.
	assert_eq(QrCode.format_bits(QrCode.Ecc.L, 0), 0b111011111000100)
	assert_eq(QrCode.format_bits(QrCode.Ecc.M, 0), 0b101010000010010)
	assert_eq(QrCode.version_bits(7), 0b000111110010010100)
	# Reed-Solomon: the classic "HELLO WORLD" 1-M example.
	var data := PackedByteArray([32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17])
	var ecc := QrCode.rs_remainder(data, QrCode.rs_generator(10))
	assert_eq(Array(ecc), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
	# Capacities.
	assert_eq(QrCode.byte_capacity(1, QrCode.Ecc.L), 17)
	assert_eq(QrCode.byte_capacity(10, QrCode.Ecc.M), 213)
	assert_eq(QrCode.byte_capacity(40, QrCode.Ecc.L), 2953)
	assert_eq(QrCode.alignment_positions(7), [6, 22, 38])


func _decode(qr: QrCode) -> PackedByteArray:
	var n := qr.size
	# Format field (first copy), matched against all 32 possibilities.
	var fb := 0
	for i in range(0, 6):
		fb |= int(qr.is_dark(8, i)) << i
	fb |= int(qr.is_dark(8, 7)) << 6
	fb |= int(qr.is_dark(8, 8)) << 7
	fb |= int(qr.is_dark(7, 8)) << 8
	for i in range(9, 15):
		fb |= int(qr.is_dark(14 - i, 8)) << i
	var level := -1
	var m := -1
	for l in 4:
		for k in 8:
			if QrCode.format_bits(l, k) == fb:
				level = l
				m = k
	assert_true(level >= 0, "format field readable")
	# Which modules are data: rebuild the function pattern map.
	var ref := QrCode.new()
	ref.version = qr.version
	ref.size = n
	ref.ecc = level
	ref.modules.resize(n * n)
	ref._is_function.resize(n * n)
	ref._draw_function_patterns()
	var bits := []
	var right := n - 1
	while right >= 1:
		if right == 6:
			right = 5
		for vert in n:
			for j in 2:
				var x := right - j
				var upward := ((right + 1) & 2) == 0
				var y := n - 1 - vert if upward else vert
				if ref._is_function[y * n + x] == 0:
					bits.append(int(qr.is_dark(x, y)) ^ int(QrCode.mask_bit(m, x, y)))
		right -= 2
	var raw := PackedByteArray()
	raw.resize(QrCode.raw_data_modules(qr.version) / 8)
	for i in raw.size() * 8:
		raw[i >> 3] |= bits[i] << (7 - (i & 7))
	# De-interleave into blocks and check each block's error correction.
	var nb: int = QrCode.NUM_BLOCKS[level][qr.version]
	var be: int = QrCode.ECC_CODEWORDS_PER_BLOCK[level][qr.version]
	var short_len := raw.size() / nb
	var num_short := nb - raw.size() % nb
	var blocks := []
	for j in nb:
		blocks.append(PackedByteArray())
	var k := 0
	var lens := []
	for j in nb:
		lens.append(short_len - be + (0 if j < num_short else 1))
	var maxd: int = lens.max()
	for i in maxd:
		for j in nb:
			if i < lens[j]:
				blocks[j].append(raw[k])
				k += 1
	var eccs := []
	for j in nb:
		eccs.append(PackedByteArray())
	for i in be:
		for j in nb:
			eccs[j].append(raw[k])
			k += 1
	var data := PackedByteArray()
	var gen := QrCode.rs_generator(be)
	for j in nb:
		assert_eq(QrCode.rs_remainder(blocks[j], gen), eccs[j], "block %d error correction" % j)
		data.append_array(blocks[j])
	# Byte mode segment.
	var bb := []
	for byte in data:
		for i in range(7, -1, -1):
			bb.append((byte >> i) & 1)
	var pos := [0] # lambdas capture locals by value; an array is shared
	var read := func(count: int) -> int:
		var v := 0
		for i in count:
			v = (v << 1) | bb[pos[0] + i]
		pos[0] += count
		return v
	assert_eq(read.call(4), 4, "byte mode")
	var count: int = read.call(8 if qr.version < 10 else 16)
	var out := PackedByteArray()
	for i in count:
		out.append(read.call(8))
	return out


func test_round_trip_small_and_large() -> void:
	for text in ["hello", "JAM1:" + "x".repeat(300), "JAM1:" + "Q9".repeat(700)]:
		var qr := QrCode.encode_text(text)
		assert_not_null(qr)
		assert_eq(_decode(qr).get_string_from_utf8(), text, "version %d, mask %d" % [qr.version, qr.mask])
	assert_null(QrCode.encode(_bytes(3000)), "too big for version 40")


func test_preset_code_as_image() -> void:
	var preset: Dictionary = PresetLibrary.list("Tangle")[0]
	var code := PresetLibrary.to_code(preset)
	var qr := QrCode.encode_text(code, QrCode.Ecc.L)
	assert_not_null(qr, "a Tangle preset code fits (%d chars)" % code.length())
	var img := qr.to_image(4, 4)
	assert_eq(img.get_width(), (qr.size + 8) * 4)
	assert_eq(_decode(qr).get_string_from_utf8(), code)


func _bytes(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	return b
