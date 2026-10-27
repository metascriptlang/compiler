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

export function wellFormedPrefix(data: Readonly<Span<uint8>>, from: int64, surrogates: boolean): int64 {
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
