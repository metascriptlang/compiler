// @stdout: native 5 2 1 | 7 8 | 2 1 | 1 2 | 4 3 | 7 8 1 true 1
// @skip-js: a byte view, a pointer variable's address, pointer arithmetic and an array of addresses have no JS location; JS refuses them at compile time
// @skip-raiser: a byte view, a pointer variable's address and pointer arithmetic are refused on the Raiser VM (no byte memory, no address arithmetic)
struct Pair { left: int32; right: int32; }

function viewed(): string {
	let n: int32 = 1;
	const typed = (n as Ptr<void>) as Ptr<int32>;
	typed[] = 5;
	let word: uint32 = 258;
	const bytes = word as Ptr<uint8>;
	return `${n} ${bytes[0]} ${bytes[1]}`;
}

function sized(): string {
	let values: uint8[2] = [7, 8];
	const first = values as Ptr<uint8>;
	return `${first[0]} ${first[1]}`;
}

function retarget(): string {
	let a: Pair = { left: 1, right: 2 };
	let b: Pair = { left: 2, right: 1 };
	let cursor = a as Ptr<Pair>;
	const slot = cursor as Ptr<Ptr<Pair>>;
	slot[] = b as Ptr<Pair>;
	return `${cursor[].left} ${cursor[].right}`;
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

console.log(`native ${viewed()} | ${sized()} | ${retarget()} | ${addresses()} | ${readOnly()} | ${arithmetic()}`);
