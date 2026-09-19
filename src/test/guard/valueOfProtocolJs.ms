// nim-guard: a read through the valueOf protocol is a call on BOTH backends, and only where the read would fail
//
// INVARIANT (checker valueOfInPlace; NIM-REF CK-14 — a converter chosen by a failed resolution):
//   a read whose resolution fails (a value slot, an operand, a missing member) and whose receiver type
//   declares `valueOf` is rewritten into `x.valueOf()` and lowered to a free call before any backend
//   sees it; a string payload is a fresh owned temp (destroyed at scope exit), a captured accessor still
//   reads the live value, a loop reads it on every iteration, and a slot that can hold the accessor (a
//   function slot, an Accessor field, an unannotated alias) receives the accessor itself.
//
// WHAT IT CATCHES: the rewrite missing on one backend (js prints a function, C reads garbage),
//   a doubled call on an explicit `x()`, a leaked or double-destroyed string temp from `"" + name`,
//   an alias or a callable slot receiving a value instead of the closure.
//
// RED MEANS: exit != 0, or GUARD-OK missing on either lane.
//
// GUARD-JS

type Acc<T> = distinct (() => T);

export function valueOf<T>(this a: Acc<T>): T { return a(); }

function sig<T>(v: T): [Acc<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Acc<T>, (n: T) => { cur = n; }];
}

interface Box { label: Acc<string>; n: Acc<number>; }

function render(b: Box): string {
	return b.label + ":" + b.n;
}

function main(): void {
	const [name, setName] = sig<string>("ab");
	const [n, setN] = sig<number>(1);
	let acc = "";
	for (let i = 0; i < 3; i += 1) {
		acc = acc + name + n;
		setN(n + 1);
	}
	const th = (): string => name + "!";
	setName("cd");
	const explicit: number = n();
	const widened: () => number = n;
	const alias = n;
	const box: Box = { label: name, n: n };
	const ok = acc === "ab1ab2ab3" && th() === "cd!" && explicit === 4 && widened() === 4
		&& alias() === 4 && name.length === 2 && render(box) === "cd:4";
	if (ok) {
		console.log("GUARD-OK");
	} else {
		console.log("GUARD-BAD", acc, th(), explicit, widened(), alias(), name.length, render(box));
	}
}

main();
