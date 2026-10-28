// How many trailing bytes of a chunk start a UTF-8 sequence the chunk ends before completing.
// A reader holds those bytes back and decodes them with the next chunk, so a character split
// across two reads is not read as two U+FFFD.
export function incompleteTail(bytes: Readonly<Span<uint8>>): int32 {
	const length = bytes.length as int32;
	let back = 1;
	while (back <= 3 && back <= length) {
		const lead = bytes[length - back];
		if ((lead & 0xC0) == 0x80) {
			back += 1;
			continue;
		}
		const need = lead >= 0xF0 && lead <= 0xF4 ? 4 : lead >= 0xE0 && lead < 0xF0 ? 3 : lead >= 0xC2 && lead < 0xE0 ? 2 : 1;
		return need > back ? back : 0;
	}
	return 0;
}

test "a sequence cut by the chunk end is held back" {
	const cut: uint8[] = [0x61, 0xE2, 0x82];
	assert incompleteTail(cut) == 2;
	const lead: uint8[] = [0x61, 0xF0];
	assert incompleteTail(lead) == 1;
	const whole: uint8[] = [0x61, 0xE2, 0x82, 0xAC];
	assert incompleteTail(whole) == 0;
	const ascii: uint8[] = [0x61, 0x62];
	assert incompleteTail(ascii) == 0;
	const stray: uint8[] = [0x61, 0x80, 0x80, 0x80, 0x80];
	assert incompleteTail(stray) == 0;
}
