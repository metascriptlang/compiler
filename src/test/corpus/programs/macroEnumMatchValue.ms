// @stdout: or=FFUII plain=FFUII if=FFUII map=PQ|QP local=20 explicit=a,b,c
// note: a `match` over an enum that yields enum members, in a function a macro calls, answers the member of the matching arm: with or-arms, with plain arms, against an if-chain, through a mapped enum consumed by a match, an `==` and an argument, held in an unannotated local and cast to int32, and over an enum with explicit values.

import { Node, NodeKind } from "std/meta";

enum Fmt { A, B, C, D, E }
enum Kind { F, I, U }
enum Pick { P, Q }
enum Stage { Vertex, Fragment }
enum Bit { VERTEX = 0x1, FRAGMENT = 0x2 }
enum E { X = 3, Y = 7, Z = 11 }

function orMatch(f: Fmt): Kind {
	return match (f) {
		Fmt.A | Fmt.B => Kind.F,
		Fmt.C => Kind.U,
		Fmt.D | Fmt.E => Kind.I,
	};
}
function plainMatch(f: Fmt): Kind {
	return match (f) {
		Fmt.A => Kind.F, Fmt.B => Kind.F, Fmt.C => Kind.U, Fmt.D => Kind.I, Fmt.E => Kind.I,
	};
}
function ifChain(f: Fmt): Kind {
	if (f == Fmt.A || f == Fmt.B) { return Kind.F; }
	if (f == Fmt.C) { return Kind.U; }
	return Kind.I;
}
function letter(k: Kind): string { return k == Kind.F ? "F" : k == Kind.U ? "U" : "I"; }

function mapped(x: Fmt): Pick {
	return match (x) { Fmt.A => Pick.P, _ => Pick.Q };
}
function viaMatch(x: Fmt): string { return match (mapped(x)) { Pick.P => "P", Pick.Q => "Q" }; }
function viaEq(x: Fmt): string { return mapped(x) == Pick.P ? "P" : "Q"; }
function arg(p: Pick): string { return p == Pick.P ? "P" : "Q"; }
function viaArg(x: Fmt): string { return arg(mapped(x)); }

function viaLocal(s: Stage): int32 {
	const bit = match (s) {
		Stage.Vertex => Bit.VERTEX,
		Stage.Fragment => Bit.FRAGMENT,
	};
	return bit as int32;
}
function explicit(e: E): string {
	return match (e) { E.X => "a", E.Y => "b", E.Z => "c" };
}

macro table(): Node {
	const fs = [Fmt.A, Fmt.B, Fmt.C, Fmt.D, Fmt.E];
	let a = ""; let b = ""; let c = "";
	for (const f of fs) { a += letter(orMatch(f)); b += letter(plainMatch(f)); c += letter(ifChain(f)); }
	const s = "or=" + a + " plain=" + b + " if=" + c
		+ " map=" + viaMatch(Fmt.A) + viaMatch(Fmt.B) + "|" + viaEq(Fmt.B) + viaArg(Fmt.A)
		+ " local=" + String(viaLocal(Stage.Fragment) * 10)
		+ " explicit=" + explicit(E.X) + "," + explicit(E.Y) + "," + explicit(E.Z);
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: s };
}

console.log(table());
