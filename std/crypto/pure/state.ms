import { wipeBytes, wipeWords } from "./secret";

export const kindSha256 = 0;
export const kindSha224 = 1;
export const kindSha512 = 2;
export const kindSha384 = 3;
export const kindSha1 = 4;
export const kindMd5 = 5;

/** The digest length in bytes of a hash kind. */
export function hashOutputSize(kind: int32): int32 {
	if (kind == kindSha256) return 32;
	if (kind == kindSha224) return 28;
	if (kind == kindSha512) return 64;
	if (kind == kindSha384) return 48;
	if (kind == kindSha1) return 20;
	return 16;
}

function isWide(kind: int32): boolean {
	return kind == kindSha512 || kind == kindSha384;
}

/** The 32-bit chaining words a hash kind keeps: 16 for the SHA-512 family, 8 for SHA-256, 5 for SHA-1, 4 for MD5. */
export function stateWords(kind: int32): int32 {
	if (isWide(kind)) return 16;
	if (kind == kindSha1) return 5;
	if (kind == kindMd5) return 4;
	return 8;
}

// On C the compression keeps its message schedule in locals and the pending block lives inside
// the state, so a digest allocates nothing but the state itself; the JS kernels loop over a
// schedule kept in the state and a block array. The block holds two blocks, so the padding that
// spills into a second block is compressed in one run.
when (!js) {
	/** The bytes a compression reads: the caller's input or the state's pending block. */
	export type HashBytes = Readonly<Span<uint8>>;
	type HashBlock = uint8[256];
	type HashSchedule = uint32[1];

	function zeroBlock(size: int32): HashBlock {
		return [0];
	}

	function zeroSchedule(): HashSchedule {
		return [0];
	}
} else {
	export type HashBytes = Readonly<uint8[]>;
	type HashBlock = uint8[];
	type HashSchedule = uint32[160];

	function zeroBlock(size: int32): HashBlock {
		return new Array<uint8>(2 * size);
	}

	function zeroSchedule(): HashSchedule {
		return [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		];
	}
}

/** The running state of one hash, with fixed typed storage so no call allocates a table. */
export class HashState {
	kind: int32;
	blockSize: int32;
	outputSize: int32;
	state: uint32[16];
	schedule: HashSchedule;
	block: HashBlock;
	filled: int32;
	length: number;
	finished: boolean;
}

export function newHashState(kind: int32): HashState {
	const blockSize = isWide(kind) ? 128 : 64;
	return {
		kind,
		blockSize,
		outputSize: hashOutputSize(kind),
		state: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		schedule: zeroSchedule(),
		block: zeroBlock(blockSize),
		filled: 0,
		length: 0,
		finished: false,
	};
}

/** Zeroes the chaining words, the schedule and the pending block with stores the C compiler keeps. */
export function wipeHashState(h: HashState): void {
	wipeWords(h.state[0..stateWords(h.kind)]);
	wipeWords(h.schedule);
	wipeBytes(h.block[0..2 * h.blockSize]);
}
