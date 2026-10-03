// @stdout: native 2 1 | 7 8 | 1 2 | 4 3 | 7 8 1 true 1 | 42 43
// @skip-js: a byte view, an integer address, pointer arithmetic and an array of addresses have no JS location; JS refuses them at compile time
// @skip-raiser: a byte view, an integer address and pointer arithmetic are refused on the Raiser VM (no byte memory, no address arithmetic)
struct Pair { left: int32; right: int32; }

extern function msPtrBits(p: Ptr<void>): uint64;

function bytesOf(): string {
	let word: Pair = { left: 258, right: 0 };
	const bytes = word as Ptr<uint8>;
	return `${bytes[0]} ${bytes[1]}`;
}

function heldAddress(): string {
	let target: Pair = { left: 41, right: 0 };
	const bits = msPtrBits(target as Ptr<void>);
	const at = bits as Ptr<Pair>;
	at[].left = at[].left + 1;
	const next = ((bits + 4) as Ptr<int32>)[];
	return `${target.left} ${next + 43}`;
}

function sized(): string {
	let values: uint8[2] = [7, 8];
	const first = values as Ptr<uint8>;
	return `${first[0]} ${first[1]}`;
}

function addresses(): string {
	let pairs: Pair[] = [{ left: 1, right: 2 }, { left: 3, right: 4 }];
	let local: Pair = { left: 2, right: 0 };
	const slots: Ptr<Pair>[] = [pairs[0] as Ptr<Pair>, local as Ptr<Pair>];
	const view: Span<Ptr<Pair>> = slots;
	const first = view as Ptr<Ptr<Pair>>;
	return `${first[][].left} ${slots[1][].left}`;
}

function readOnly(): string {
	const fixed: Pair = { left: 4, right: 3 };
	const view = fixed as Ptr<Pair>;
	return `${view[].left} ${view[].right}`;
}

function pick(ref calls: int32): int32 { calls += 1; return 2; }

function arithmetic(): string {
	let pairs: Pair[] = [{ left: 1, right: 2 }, { left: 3, right: 4 }, { left: 5, right: 6 }];
	const p = (pairs as Span<Pair>) as Ptr<Pair>;
	const q = p + 1;
	q[].right = 7;
	let calls: int32 = 0;
	p[pick(calls)].left = 8;
	return `${pairs[1].right} ${pairs[2].left} ${q - p} ${q > p} ${calls}`;
}

console.log(`native ${bytesOf()} | ${sized()} | ${addresses()} | ${readOnly()} | ${arithmetic()} | ${heldAddress()}`);
