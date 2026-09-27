// note: main-reg-2. A nameless object type that reaches itself through `| null` (`type N = { next: N | null }`, an optional field, two aliases, a union alias, an interface) shaped its nullable field before the alias resolved: a value Maybe with no incref, so a stored link double-destroyed. Fix (58668699): the nullable union of a forward alias settles once the alias resolves. Each shape links a cycle, reads through it and unlinks it.

type N = { next: N | null; s: string };

type A = { b: B | null; s: string };
type B = { a: A | null; t: string };

type O = { next?: O; s: string; k: int32 };

type W = { next: U; w: string };
type U = W | null;

type H = { link: L; s: string };
interface L { back: H | null }

function selfCycle(i: int32): string {
	const a: N = { next: null, s: "a" + i.toString() };
	const b: N = { next: a, s: "b" + i.toString() };
	a.next = b;
	const out = a.next!.s + b.next!.s;
	a.next = null;
	return out;
}

function mutualCycle(i: int32): string {
	const x: A = { b: null, s: "x" + i.toString() };
	const y: B = { a: x, t: "y" + i.toString() };
	x.b = y;
	const out = x.b!.t + y.a!.s;
	x.b = null;
	return out;
}

function optionalCycle(i: int32): string {
	const a: O = { s: "o" + i.toString(), k: i };
	const b: O = { next: a, s: "p" + i.toString(), k: i + 1 };
	a.next = b;
	const out = a.next!.s + b.next!.s + (a.next!.k + b.next!.k).toString();
	a.next = null;
	return out;
}

function unionAliasCycle(i: int32): string {
	const a: W = { next: null, w: "w" + i.toString() };
	const b: W = { next: a, w: "v" + i.toString() };
	a.next = b;
	const out = a.next!.w + b.next!.w;
	a.next = null;
	return out;
}

function interfaceCycle(i: int32): string {
	const l: L = { back: null };
	const h: H = { link: l, s: "h" + i.toString() };
	l.back = h;
	const out = h.link.back!.s;
	l.back = null;
	return out;
}

function run(): void {
	for (let i: int32 = 0; i < 3; i += 1) {
		console.log(selfCycle(i) + " " + mutualCycle(i) + " " + optionalCycle(i) + " " + unionAliasCycle(i) + " " + interfaceCycle(i));
	}
}
run();
