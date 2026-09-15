// bug164 — an accessor auto-called by its source type broke aliases and ran handlers on read
// Symptom: with the source-typed auto-call of bug154, `const d = count` snapshotted the value so `d()` failed,
//          `id(count)()` and `[count][0]()` failed the same way, `mk() * 2` was rejected, and aliasing a
//          `distinct (() => void)` handler (`const h = onClick`) ran it.
// Root cause: the implicit call fired on the type of every read, not on a failed resolution, so positions
//             that could hold the accessor itself received its value.
// Fix: the valueOf protocol — `valueOf(this x: T): U` is inserted only where resolution fails (a value slot,
//      an operand, a condition, a missing member, an index, a switch, `as`, an extension or overload
//      argument), one step, and only for a receiver whose extension names that type.

type Acc164<T> = distinct (() => T);
type Handler164 = distinct (() => void);

export function valueOf<T>(this a: Acc164<T>): T { return a(); }

function makeSignal164<T>(v: T): [Acc164<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Acc164<T>, (n: T) => { cur = n; }];
}

function id164<T>(x: T): T { return x; }
function mk164(a: Acc164<number>): Acc164<number> { return a; }
function attr164(v: string): string { return "static " + v; }
function attr164(v: Acc164<string>): string { return "dyn " + v(); }
export function addTo164(this n: number, x: number): number { return n + x; }

let hits164: int32 = 0;
let calls164: int32 = 0;

test "bug164: an alias, a generic result and an array element keep the live accessor" {
	const [count, setCount] = makeSignal164<number>(5);
	const d = count;
	const g = id164(count);
	const arr = [count, count];
	setCount(9);
	assert d() === 9;
	assert g() === 9;
	assert arr.length === 2;
	assert arr[0]() === 9;
}

test "bug164: a call result of accessor type is read as an operand" {
	const [count, setCount] = makeSignal164<number>(5);
	assert mk164(count) * 2 === 10;
}

test "bug164: aliasing a handler does not run it" {
	hits164 = 0;
	const onClick = (() => { hits164 = hits164 + 1; }) as Handler164;
	const h = onClick;
	const hs = [onClick];
	assert hits164 === 0;
	h();
	hs[0]();
	assert hits164 === 2;
}

test "bug164: an overload picks the candidate that holds the accessor" {
	const [name, setName] = makeSignal164<string>("neo");
	assert attr164(name) === "dyn neo";
	assert attr164("lit") === "static lit";
}

test "bug164: operands, equality, compound assignment and unary minus read the value" {
	const [count, setCount] = makeSignal164<number>(5);
	assert count === 5;
	assert -count === -5;
	let t: number = 1;
	t += count;
	assert t === 6;
}

test "bug164: an index, a switch and an assertion read the value" {
	const [count, setCount] = makeSignal164<number>(5);
	const [ix, setIx] = makeSignal164<int32>(1);
	const arr: number[] = [10, 20, 30];
	assert arr[ix] === 20;
	let s = "";
	switch (count) { case 5: s = "five"; break; default: s = "other"; }
	assert s === "five";
	const q = count as number;
	assert q === 5;
}

test "bug164: a missing member and an extension argument read the value" {
	const [count, setCount] = makeSignal164<number>(5);
	const [name, setName] = makeSignal164<string>("neo");
	assert count.toString() === "5";
	assert name.toUpperCase() === "NEO";
	const base: number = 1;
	assert base.addTo164(count) === 6;
	assert Math.floor(count) === 5;
}

test "bug164: a boolean accessor reads in a ternary, a logical operand and a negation" {
	const [flag, setFlag] = makeSignal164<boolean>(true);
	assert (flag ? 1 : 2) === 1;
	assert (flag && true) === true;
	assert !flag === false;
	setFlag(false);
	assert (flag ? 1 : 2) === 2;
}

test "bug164: each implicit read calls the accessor once and an alias never calls it" {
	calls164 = 0;
	const counted = (() => { calls164 = calls164 + 1; return 5; }) as Acc164<number>;
	const al = counted;
	assert calls164 === 0;
	const r = counted * 2 + counted;
	assert r === 15;
	assert calls164 === 2;
}
