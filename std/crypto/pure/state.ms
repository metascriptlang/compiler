export const kindSha256 = 0;
export const kindSha224 = 1;
export const kindSha512 = 2;
export const kindSha384 = 3;
export const kindSha1 = 4;
export const kindMd5 = 5;

/** The running state of one hash, with fixed typed storage so no call allocates a table. */
export class HashState {
	kind: int32;
	blockSize: int32;
	outputSize: int32;
	state: uint32[16];
	schedule: uint32[160];
	block: uint8[];
	filled: int32;
	length: number;
	finished: boolean;
}

export function newHashState(kind: int32): HashState {
	const wide = kind == kindSha512 || kind == kindSha384;
	return {
		kind,
		blockSize: wide ? 128 : 64,
		outputSize: kind == kindSha256 ? 32 : kind == kindSha224 ? 28 : kind == kindSha512 ? 64 : kind == kindSha384 ? 48 : kind == kindSha1 ? 20 : 16,
		state: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		schedule: [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		],
		block: new Array<uint8>(wide ? 128 : 64),
		filled: 0,
		length: 0,
		finished: false,
	};
}
