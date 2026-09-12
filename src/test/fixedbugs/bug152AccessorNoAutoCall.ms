// bug152 — the positions where an accessor must stay an accessor
// Symptom: (pin) with the implicit call of bug154 in place, a function-typed slot, a callable parameter, an explicit
//          call, an Accessor slot, a nullable Accessor field, an overloaded call and a generic parameter must keep
//          today's meaning — this file is the contract the rewrite must not cross.
// Root cause: n/a (pin).
// Fix: autoCallIfAccessor consults the expected type (expectsCallable) and the suppression counter.

type Acc152<T> = distinct (() => T);

function makeSignal152<T>(v: T): [Acc152<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Acc152<T>, (n: T) => { cur = n; }];
}

function take152(g: () => number): number { return g(); }
function on152(cb: () => number, tag: string): number { return cb() + tag.length; }
function on152(v: number, n: number): number { return v + n; }
function id152<T>(x: T): T { return x; }

interface Opt152 { v?: Acc152<number> | null; }

test "a function-typed slot receives the accessor itself" {
	const [c, setC] = makeSignal152<number>(1);
	const f: () => number = c;
	setC(4);
	assert f() === 4;
}

test "an explicit call is not doubled" {
	const [c, setC] = makeSignal152<number>(1);
	const v: number = c();
	assert v === 1;
}

test "a callable parameter receives the accessor itself" {
	const [c, setC] = makeSignal152<number>(1);
	setC(9);
	assert take152(c) === 9;
}

test "an overloaded call follows the winning formal" {
	const [c, setC] = makeSignal152<number>(1);
	assert on152(c, "ab") === 3;
	assert on152(c, 10) === 11;
}

test "a generic parameter binds to the value" {
	const [c, setC] = makeSignal152<number>(1);
	const v: number = id152(c);
	assert v === 1;
}

test "an Accessor slot and a nullable Accessor field receive the accessor" {
	const [c, setC] = makeSignal152<number>(1);
	const a2: Acc152<number> = c;
	const p: Opt152 = { v: c };
	let r: number = 0;
	if (p.v != null) { r = p.v * 2; }
	setC(6);
	assert a2() === 6;
	assert r === 2;
}
