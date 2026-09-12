// Parity program — `BitSet<E>` built and queried inside macro and @comptime
// bodies: the comptime engine must produce the same bits as the runtime.
//
// @stdout: 5,true,false,6,4,true,false|5,true,false,6,4,true,false|5 true
// @exit: 0

import { Node } from "std/meta/node";

export enum E { A, B, C }

macro inMacro(): Node {
	const s: BitSet<E> = E.A | E.C;
	const t = s.incl(E.B).excl(E.A);
	const u = s & (E.C | E.B);
	const z = 0 as BitSet<E>;
	return quote { ${s as uint32 as int32} + "," + ${s.has(E.C)} + "," + ${s.has(E.B)} + "," + ${t as uint32 as int32} + "," + ${u as uint32 as int32} + "," + ${z.isEmpty()} + "," + ${s.isEmpty()} };
}

function atRuntime(): string {
	const s: BitSet<E> = E.A | E.C;
	const t = s.incl(E.B).excl(E.A);
	const u = s & (E.C | E.B);
	const z = 0 as BitSet<E>;
	return (s as uint32 as int32) + "," + s.has(E.C) + "," + s.has(E.B) + "," + (t as uint32 as int32) + "," + (u as uint32 as int32) + "," + z.isEmpty() + "," + s.isEmpty();
}

const ctWord: int32 = @comptime { const s: BitSet<E> = E.A | E.C; return s as uint32 as int32; };
const ctHas: boolean = @comptime { const s: BitSet<E> = E.A | E.C; return s.has(E.C); };

console.log(inMacro() + "|" + atRuntime() + "|" + ctWord + " " + ctHas);
