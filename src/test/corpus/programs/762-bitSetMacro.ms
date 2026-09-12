// Parity program — `BitSet<E>` built and queried inside macro and @comptime
// bodies: the comptime engine must produce the same bits as the runtime.
//
// @stdout: 5,true,false,6,4,true,false|5,true,false,6,4,true,false|5 true|true,false,true,false,true,true,true,true,true,true|true,false,true,false,true,true,true,true,true,true|false,true,false,false,false,true|false,true,false,false,false,true
// @exit: 0

import { Node } from "std/meta/node";

export enum E { A, B, C }
export enum L { M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15,M16,M17,M18,M19,M20,M21,M22,M23,M24,M25,M26,M27,M28,M29,M30,M31,M32,M33,M34,M35,M36,M37,M38,M39 }
export enum W { M0,M1,M2,M3,M4,M5,M6,M7,M8,M9,M10,M11,M12,M13,M14,M15,M16,M17,M18,M19,M20,M21,M22,M23,M24,M25,M26,M27,M28,M29,M30,M31,M32,M33,M34,M35,M36,M37,M38,M39,M40,M41,M42,M43,M44,M45,M46,M47,M48,M49,M50,M51,M52,M53,M54,M55,M56,M57,M58,M59,M60,M61,M62,M63,M64,M65,M66,M67,M68,M69,M70,M71,M72,M73,M74,M75,M76,M77,M78,M79,M80,M81,M82,M83,M84,M85,M86,M87,M88,M89,M90,M91,M92,M93,M94,M95,M96,M97,M98,M99 }

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

macro inMacroArray(): Node {
	const a: BitSet<W> = W.M99 | W.M1;
	const b: BitSet<W> = W.M1 | W.M99;
	const c: BitSet<W> = W.M98 | W.M1;
	const z = 0 as BitSet<W>;
	return quote { ${a.has(W.M99)} + "," + ${a.has(W.M0)} + "," + ${a.incl(W.M70).has(W.M70)} + "," + ${a.excl(W.M99).has(W.M99)} + "," + ${z.isEmpty()} + "," + ${a == b} + "," + ${a != c} + "," + ${(a & c).has(W.M1)} + "," + ${(a | c).has(W.M98)} + "," + ${(a ^ b).isEmpty()} };
}

function atRuntimeArray(): string {
	const a: BitSet<W> = W.M99 | W.M1;
	const b: BitSet<W> = W.M1 | W.M99;
	const c: BitSet<W> = W.M98 | W.M1;
	const z = 0 as BitSet<W>;
	return a.has(W.M99) + "," + a.has(W.M0) + "," + a.incl(W.M70).has(W.M70) + "," + a.excl(W.M99).has(W.M99) + "," + z.isEmpty() + "," + (a == b) + "," + (a != c) + "," + (a & c).has(W.M1) + "," + (a | c).has(W.M98) + "," + (a ^ b).isEmpty();
}

macro inMacroWide(): Node {
	const s: BitSet<L> = L.M39 | L.M1;
	const t: BitSet<L> = L.M7 | L.M1;
	return quote { ${s.has(L.M7)} + "," + ${s.has(L.M39)} + "," + ${s == t} + "," + ${(L.M33 | L.M0).has(L.M1)} + "," + ${s.excl(L.M39).isEmpty()} + "," + ${s.incl(L.M38).has(L.M38)} };
}

function atRuntimeWide(): string {
	const s: BitSet<L> = L.M39 | L.M1;
	const t: BitSet<L> = L.M7 | L.M1;
	return s.has(L.M7) + "," + s.has(L.M39) + "," + (s == t) + "," + (L.M33 | L.M0).has(L.M1) + "," + s.excl(L.M39).isEmpty() + "," + s.incl(L.M38).has(L.M38);
}

console.log(inMacro() + "|" + atRuntime() + "|" + ctWord + " " + ctHas + "|" + inMacroArray() + "|" + atRuntimeArray() + "|" + inMacroWide() + "|" + atRuntimeWide());
