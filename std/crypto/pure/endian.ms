/** Little- and big-endian word loads and stores on byte arrays, shared by the portable kernels. */

import { InputBytes } from "./bytes";

@inline
export function load32LE(data: InputBytes, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
}

@inline
export function store32LE(out: uint8[], at: int32, word: uint32): void {
	out[at] = (word & 0xff) as uint8;
	out[at + 1] = ((word >> 8) & 0xff) as uint8;
	out[at + 2] = ((word >> 16) & 0xff) as uint8;
	out[at + 3] = (word >> 24) as uint8;
}

@inline
export function load32BE(data: InputBytes, at: int32): uint32 {
	return ((data[at] as uint32) << 24) | ((data[at + 1] as uint32) << 16) | ((data[at + 2] as uint32) << 8) | (data[at + 3] as uint32);
}

@inline
export function store32BE(out: uint8[], at: int32, value: uint32): void {
	out[at] = (value >> 24) as uint8;
	out[at + 1] = ((value >> 16) & 0xff) as uint8;
	out[at + 2] = ((value >> 8) & 0xff) as uint8;
	out[at + 3] = (value & 0xff) as uint8;
}

@inline
export function load64BE(data: InputBytes, at: int32): uint64 {
	return ((load32BE(data, at) as uint64) << 32) | (load32BE(data, at + 4) as uint64);
}

@inline
export function store64BE(out: uint8[], at: int32, value: uint64): void {
	for (let i = 0; i < 8; i++) out[at + i] = ((value >> ((56 - 8 * i) as uint64)) & 0xff) as uint8;
}
