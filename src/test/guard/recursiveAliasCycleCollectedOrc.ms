// nim-guard: a nameless object type that reaches itself through `| null` is one
// cyclic type, whatever the order its aliases are declared in: a copy into the
// nullable field increfs, and under ORC the cycle is collected.
//
// Nim semtypes.nim:1834-1866 returns a tyForward for a generic invocation whose
// argument is still forward (`Option[Foo]` inside Foo) and semstmts.nim:1805-1850
// typeSectionFinalPass re-sems it with assignType once every forward has a body;
// types.nim:208 iterOverTypeAux marks every type it enters. Proven red on main
// c36ed0ab: a type error here, and alone each shape double-destroys or leaks.
//
// RED MEANS a nullable union of a forward alias is shaped before the alias
// resolves, or a walk over a recursive nameless type lost its visited mark; run
// /trace-nim on settleForwardTypes (checker/resolvePass.ms).
//
// GUARD-BALANCE-ORC TOTAL
// GUARD-JS

type N = { next: N | null; s: string };

type A = { b: B | null; s: string };
type B = { a: A | null; t: string };

type O = { next?: O; s: string; k: int32 };

type W = { next: U; w: string };
type U = W | null;

type H = { link: L; s: string };
interface L { back: H | null }

function selfCycle(i: int32): int32 {
	const a: N = { next: null, s: "a" + i.toString() };
	const b: N = { next: a, s: "b" + i.toString() };
	a.next = b;
	return (a.next!.s.length + b.next!.s.length) as int32;
}

function mutualCycle(i: int32): int32 {
	const x: A = { b: null, s: "x" + i.toString() };
	const y: B = { a: x, t: "y" + i.toString() };
	x.b = y;
	return (x.b!.t.length + y.a!.s.length) as int32;
}

function optionalCycle(i: int32): int32 {
	const a: O = { s: "o" + i.toString(), k: i };
	const b: O = { next: a, s: "p" + i.toString(), k: i };
	a.next = b;
	return (a.next!.s.length + b.next!.s.length) as int32;
}

function unionAliasCycle(i: int32): int32 {
	const a: W = { next: null, w: "w" + i.toString() };
	const b: W = { next: a, w: "v" + i.toString() };
	a.next = b;
	return (a.next!.w.length + b.next!.w.length) as int32;
}

function interfaceCycle(i: int32): int32 {
	const l: L = { back: null };
	const h: H = { link: l, s: "h" + i.toString() };
	l.back = h;
	return h.link.back!.s.length as int32;
}

function main(): void {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 50; i += 1) {
		s = s + selfCycle(i) + mutualCycle(i) + optionalCycle(i) + unionAliasCycle(i) + interfaceCycle(i);
	}
	console.log(s);
	console.log("GUARD-OK");
}
main();
