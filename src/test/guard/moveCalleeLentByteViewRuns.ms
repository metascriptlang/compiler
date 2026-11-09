// nim-guard: spawn { move } — a factory that lends C a read-only byte view
//   keeps its move.
//
// INVARIANT (isolation check, extern parameters, NIM-REF AN-2): an extern
//   whose pointer-holding parameters are all Readonly<Span<T>> of value-only
//   elements, and whose return carries no pointer, keeps no address of what it
//   is lent: the FFI contract forbids C to retain a borrowed buffer, as it
//   does a borrowed string. A factory, or a constructor, that hands such an
//   extern a view into the value it builds therefore keeps its move.
//
// WHAT IT CATCHES: the extern parameter test charging a lent read-only byte
//   view while it trusts a lent string, which refused the move of a Wings
//   sender state built through std's byte search.
//
// RED MEANS: a shape below is refused (check error), or the moved value
//   carries the wrong contents.

import { byteEqAt } from "std/core/string/bytes";

interface Framed { bytes: uint8[]; magic: boolean; }

function frame(): Framed {
	const bytes: uint8[] = [77, 83, 1];
	const magic: uint8[] = [77, 83];
	return { bytes: bytes, magic: byteEqAt(bytes, 0, magic) };
}

class Packet {
	bytes: uint8[] = [77, 83, 2, 9];
	magic: boolean = false;
	constructor() {
		const tag: uint8[] = [77, 83];
		this.magic = byteEqAt(this.bytes, 0, tag);
	}
}

async function fromFactory(): Promise<int32> {
	const f = frame();
	return await spawn((): int32 => { f.bytes.push(4); return (f.magic ? 10 : 0) + (f.bytes.length as int32); }, { move: [f] });
}

async function fromConstructor(): Promise<int32> {
	const p = new Packet();
	return await spawn((): int32 => (p.magic ? 10 : 0) + (p.bytes[3] as int32), { move: [p] });
}

async function main(): Promise<int32> {
	const a = await fromFactory();
	const b = await fromConstructor();
	if (a != 14) { throw "GUARD RED: fromFactory"; }
	if (b != 19) { throw "GUARD RED: fromConstructor"; }
	console.log("GUARD-OK");
	return 0;
}
await main();
