const HEADER: int32 = 88;
const RESERVE: int32 = 10240;

function padded(length: int32): int32 {
	return (length + 7) / 8 * 8;
}

function pushWord(bytes: uint8[], value: uint64): void {
	for (let shift: uint64 = 0; shift < 64; shift += 8) { bytes.push(((value >> shift) & 0xff) as uint8); }
}

function pushRun(bytes: uint8[], value: uint8, length: int32): void {
	for (let at = 0; at < length; at++) { bytes.push(value); }
}

// The runtime's input serialization: firsts[i] is the index of the first account whose record account i repeats
// (its own index for a record). A record's key bytes are i + 1, its owner bytes 0xa0, its lamports 1000 + i, its
// data bytes i * 16 + k, with the runtime's reserve and rent epoch after the data.
export function serializeInput(firsts: Readonly<Span<int32>>, dataLengths: Readonly<Span<int32>>, data: Readonly<Span<uint8>>, program: uint8): uint8[] {
	const bytes: uint8[] = [];
	pushWord(bytes, firsts.length as uint64);
	for (let index = 0; index < firsts.length; index++) {
		if (firsts[index] != index) {
			bytes.push(firsts[index] as uint8);
			pushRun(bytes, 0, 7);
			continue;
		}
		const length = dataLengths[index];
		bytes.push(0xff);
		bytes.push(1);
		bytes.push(1);
		bytes.push(0);
		pushRun(bytes, 0, 4);
		pushRun(bytes, (index + 1) as uint8, 32);
		pushRun(bytes, 0xa0, 32);
		pushWord(bytes, (1000 + index) as uint64);
		pushWord(bytes, length as uint64);
		for (let at = 0; at < length; at++) { bytes.push((index * 16 + at) as uint8); }
		pushRun(bytes, 0, padded(length) - length + RESERVE);
		pushWord(bytes, 0xffffffffffffffff);
	}
	pushWord(bytes, data.length as uint64);
	for (let at = 0; at < data.length; at++) { bytes.push(data[at]); }
	pushRun(bytes, program, 32);
	return bytes;
}

export function recordSize(length: int32): int32 {
	return HEADER + padded(length) + RESERVE + 8;
}
