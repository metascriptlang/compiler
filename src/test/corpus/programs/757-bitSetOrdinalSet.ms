// Parity program — `BitSet<E>` holds a set of enum members in one machine word,
// with a member's bit position taken from its ordinal. `A | B` builds the set,
// `.incl` / `.excl` add and remove, `.has` asks.
//
// @stdout: 10,11,9,true,false,true,false,0,true
// @exit: 0

enum Flag { Mutable, Used, Consumed, Cursor }

function main(): void {
	const base: BitSet<Flag> = Flag.Used | Flag.Cursor;
	const added = base.incl(Flag.Mutable);
	const removed = added.excl(Flag.Used);
	const empty: BitSet<Flag> = 0 as BitSet<Flag>;
	console.log(`${base as int64},${added as int64},${removed as int64},${removed.has(Flag.Mutable)},${removed.has(Flag.Used)},${removed.has(Flag.Cursor)},${removed.has(Flag.Consumed)},${empty as int64},${empty.isEmpty()}`);
}
main();
