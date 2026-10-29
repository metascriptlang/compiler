import { EncodingBytes, EncodingIndex } from "std/crypto/encodingOutput";

// Length of the well-formed sequence at `i`, or minus the length of its longest valid prefix
// (at least one byte), which decodes to one U+FFFD (WHATWG UTF-8 decode, maximal subparts).
export function utf8StepAt(data: Readonly<Span<uint8>>, i: int64, surrogates: boolean): int64 {
	const lead = data[i];
	if (lead < 0x80) return 1;
	if (surrogates && lead == 0xED && surrogateAt(data, i)) return 3;
	let need: int64 = 0;
	let low: uint8 = 0x80;
	let high: uint8 = 0xBF;
	if (lead >= 0xC2 && lead <= 0xDF) {
		need = 1;
	} else if (lead >= 0xE0 && lead <= 0xEF) {
		need = 2;
		if (lead == 0xE0) low = 0xA0;
		if (lead == 0xED) high = 0x9F;
	} else if (lead >= 0xF0 && lead <= 0xF4) {
		need = 3;
		if (lead == 0xF0) low = 0x90;
		if (lead == 0xF4) high = 0x8F;
	} else {
		return -1;
	}
	const length = data.length as int64;
	for (let j = i + 1; j <= i + need; j++) {
		if (j >= length || data[j] < low || data[j] > high) return i - j;
		low = 0x80;
		high = 0xBF;
	}
	return need + 1;
}

function surrogateAt(data: Readonly<Span<uint8>>, i: int64): boolean {
	return i + 2 < (data.length as int64) && data[i + 1] >= 0xA0 && data[i + 1] <= 0xBF && (data[i + 2] & 0xC0) == 0x80;
}

export function surrogatePairAt(data: Readonly<Span<uint8>>, i: int64): boolean {
	return i + 5 < (data.length as int64)
		&& data[i] == 0xED && data[i + 1] >= 0xA0 && data[i + 1] <= 0xAF && (data[i + 2] & 0xC0) == 0x80
		&& data[i + 3] == 0xED && data[i + 4] >= 0xB0 && data[i + 4] <= 0xBF && (data[i + 5] & 0xC0) == 0x80;
}

when (c) {
	@inline
	function byteOf(data: Readonly<Span<uint8>>, i: int64): int32 {
		return (data as Readonly<Ptr<uint8>>)[i] as int32;
	}
} else {
	@inline
	function byteOf(data: Readonly<Span<uint8>>, i: int64): int32 {
		return data[i] as int32;
	}
}

export function wellFormedPrefix(data: Readonly<Span<uint8>>, from: int64, surrogates: boolean): int64 {
	const length = data.length as int64;
	const room = length - 4;
	let i = from;
	while (i < length) {
		const lead = byteOf(data, i);
		if (lead < 0x80) {
			i += 1;
			if (i <= room && (byteOf(data, i) | byteOf(data, i + 1) | byteOf(data, i + 2)) < 0x80) i += 3;
			continue;
		}
		if (i <= room) {
			const b1 = byteOf(data, i + 1) ^ 0x80;
			if (lead < 0xE0) {
				if (lead >= 0xC2 && b1 < 0x40) {
					i += 2;
					continue;
				}
			} else if (lead < 0xF0) {
				if (lead != 0xED && (b1 | (byteOf(data, i + 2) ^ 0x80)) < 0x40 && (lead != 0xE0 || b1 >= 0x20)) {
					i += 3;
					continue;
				}
			} else if (lead < 0xF4) {
				if ((b1 | (byteOf(data, i + 2) ^ 0x80) | (byteOf(data, i + 3) ^ 0x80)) < 0x40 && (lead != 0xF0 || b1 >= 0x10)) {
					i += 4;
					continue;
				}
			}
		}
		if (surrogates && surrogatePairAt(data, i)) return i;
		const step = utf8StepAt(data, i, surrogates);
		if (step < 0) return i;
		i += step;
	}
	return i;
}

export function repairedLength(data: Readonly<Span<uint8>>, from: int64, surrogates: boolean): int64 {
	const length = data.length as int64;
	let size = from;
	let i = from;
	while (i < length) {
		if (surrogates && surrogatePairAt(data, i)) {
			size += 4;
			i += 6;
			continue;
		}
		const step = utf8StepAt(data, i, surrogates);
		size += step > 0 ? step : 3;
		i += step > 0 ? step : -step;
	}
	return size;
}

export function writeRepaired(data: Readonly<Span<uint8>>, from: int64, surrogates: boolean, out: EncodingBytes): void {
	const length = data.length as int64;
	let at = from as EncodingIndex;
	let i = from;
	while (i < length) {
		if (surrogates && surrogatePairAt(data, i)) {
			const high = (((data[i + 1] as int32) & 0x0F) << 6) | ((data[i + 2] as int32) & 0x3F);
			const low = (((data[i + 4] as int32) & 0x0F) << 6) | ((data[i + 5] as int32) & 0x3F);
			const point = 0x10000 + ((high << 10) | low);
			out[at] = (0xF0 | (point >> 18)) as uint8;
			out[at + 1] = (0x80 | ((point >> 12) & 0x3F)) as uint8;
			out[at + 2] = (0x80 | ((point >> 6) & 0x3F)) as uint8;
			out[at + 3] = (0x80 | (point & 0x3F)) as uint8;
			at += 4;
			i += 6;
			continue;
		}
		const step = utf8StepAt(data, i, surrogates);
		if (step > 0) {
			for (let k: int64 = 0; k < step; k++) out[at + (k as EncodingIndex)] = data[i + k];
			at += step as EncodingIndex;
			i += step;
		} else {
			out[at] = 0xEF;
			out[at + 1] = 0xBF;
			out[at + 2] = 0xBD;
			at += 3;
			i -= step;
		}
	}
}

function referencePrefix(data: Readonly<Span<uint8>>, from: int64, surrogates: boolean): int64 {
	const length = data.length as int64;
	let i = from;
	while (i < length) {
		if (data[i] < 0x80) {
			i += 1;
			continue;
		}
		if (surrogates && surrogatePairAt(data, i)) return i;
		const step = utf8StepAt(data, i, surrogates);
		if (step < 0) return i;
		i += step;
	}
	return i;
}

const PROBE_BYTES: number[] = [
	0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xAF, 0xB0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF,
	0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF,
];

function bytesOf(size: int32): uint8[] {
	return new Array<uint8>(size as int64);
}

function sameBothModes(bytes: uint8[]): boolean {
	const probe = bytes as Readonly<Span<uint8>>;
	const limit = bytes.length < 2 ? 1 : 2;
	for (let from = 0; from < limit; from++) {
		if (wellFormedPrefix(probe, from, false) != referencePrefix(probe, from, false)) return false;
		if (wellFormedPrefix(probe, from, true) != referencePrefix(probe, from, true)) return false;
	}
	return true;
}

function probeSequence(picks: number[]): boolean {
	const size = picks.length;
	const plain = bytesOf(size);
	const padded = bytesOf(size + 4);
	const framed = bytesOf(size + 5);
	framed[0] = 0x61;
	for (let k = 0; k < size; k++) {
		const byte = PROBE_BYTES[picks[k]] as uint8;
		plain[k] = byte;
		padded[k] = byte;
		framed[k + 1] = byte;
	}
	for (let k = 0; k < 4; k++) {
		padded[size + k] = (0x61 + k) as uint8;
		framed[size + 1 + k] = (0x61 + k) as uint8;
	}
	return sameBothModes(plain) && sameBothModes(padded) && sameBothModes(framed);
}

test "wellFormedPrefix matches the byte-at-a-time scan on every short sequence of probe bytes" {
	const count = PROBE_BYTES.length;
	for (let a = 0; a < count; a++) {
		assert probeSequence([a]);
		for (let b = 0; b < count; b++) {
			assert probeSequence([a, b]);
			for (let c = 0; c < count; c++) {
				assert probeSequence([a, b, c]);
				for (let d = 0; d < count; d++) assert probeSequence([a, b, c, d]);
			}
		}
	}
}

test "wellFormedPrefix matches the byte-at-a-time scan on seeded random strings" {
	let state: uint32 = 12345;
	for (let round = 0; round < 6000; round++) {
		state = state * 1664525 + 1013904223;
		const size = ((state >> 16) % 80) as int32;
		const bytes = bytesOf(size);
		for (let k = 0; k < size; k++) {
			state = state * 1664525 + 1013904223;
			const pick = (state >> 16) as int32;
			const kind = pick % 10;
			if (kind < 4) {
				bytes[k] = PROBE_BYTES[(pick >> 4) % PROBE_BYTES.length] as uint8;
			} else if (kind < 6) {
				bytes[k] = (0x80 + ((pick >> 4) % 0x40)) as uint8;
			} else if (kind < 8) {
				bytes[k] = (0xC2 + ((pick >> 4) % 0x33)) as uint8;
			} else {
				bytes[k] = (0x20 + ((pick >> 4) % 0x5F)) as uint8;
			}
		}
		assert sameBothModes(bytes);
	}
}

test "wellFormedPrefix matches the byte-at-a-time scan on long valid text with one fault" {
	const unit: number[] = [0x61, 0xC3, 0xA9, 0xE6, 0x97, 0xA5, 0xF0, 0x9F, 0x98, 0x80, 0x20, 0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80];
	const faults: number[] = [0x80, 0xC0, 0xC3, 0xE2, 0xED, 0xF0, 0xF4, 0xFF];
	const size = unit.length * 3;
	for (const fault of faults) {
		for (let at = 0; at < 40; at++) {
			const bytes = bytesOf(size);
			for (let k = 0; k < size; k++) bytes[k] = unit[k % unit.length] as uint8;
			bytes[at] = fault as uint8;
			assert sameBothModes(bytes);
		}
	}
	const clean = bytesOf(size);
	for (let k = 0; k < size; k++) clean[k] = unit[k % unit.length] as uint8;
	assert wellFormedPrefix(clean, 0, false) == size;
	assert wellFormedPrefix(clean, 0, true) == size;
}
