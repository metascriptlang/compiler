// @stdout: byte 8 8 true false 0 1 true | word 8 8 true false 0 1 true
// @exit: 0

enum ByteFlag { Changed, Paint }
enum WordFlag { Changed, Paint, C, D, E, F, G, H, High }
interface ByteOwner { bits: Vec<BitSet<ByteFlag>>; }
interface WordOwner { bits: Vec<BitSet<WordFlag>>; }

function byteLifecycle(): string {
	const owner: ByteOwner = { bits: [] };
	const changed = (0 as BitSet<ByteFlag>).incl(ByteFlag.Changed);
	for (let i: int32 = 0; i < 8; i++) { owner.bits.push(changed); }
	let copy: Vec<BitSet<ByteFlag>> = owner.bits;
	const before = owner.bits.length;
	const copied = copy.length;
	copy[0] = (0 as BitSet<ByteFlag>).incl(ByteFlag.Paint);
	const kept = owner.bits[0].has(ByteFlag.Changed);
	const shared = owner.bits[0].has(ByteFlag.Paint);
	owner.bits = new Array(0);
	const empty = owner.bits.length;
	copy = new Array(0);
	owner.bits.push((0 as BitSet<ByteFlag>).incl(ByteFlag.Paint));
	return `byte ${before} ${copied} ${kept} ${shared} ${empty} ${owner.bits.length} ${owner.bits[0].has(ByteFlag.Paint)}`;
}

function wordLifecycle(): string {
	const owner: WordOwner = { bits: [] };
	const changed = (0 as BitSet<WordFlag>).incl(WordFlag.Changed);
	for (let i: int32 = 0; i < 8; i++) { owner.bits.push(changed); }
	let copy: Vec<BitSet<WordFlag>> = owner.bits;
	const before = owner.bits.length;
	const copied = copy.length;
	copy[0] = (0 as BitSet<WordFlag>).incl(WordFlag.High);
	const kept = owner.bits[0].has(WordFlag.Changed);
	const shared = owner.bits[0].has(WordFlag.High);
	owner.bits = new Array(0);
	const empty = owner.bits.length;
	copy = new Array(0);
	owner.bits.push((0 as BitSet<WordFlag>).incl(WordFlag.High));
	return `word ${before} ${copied} ${kept} ${shared} ${empty} ${owner.bits.length} ${owner.bits[0].has(WordFlag.High)}`;
}

console.log(`${byteLifecycle()} | ${wordLifecycle()}`);
