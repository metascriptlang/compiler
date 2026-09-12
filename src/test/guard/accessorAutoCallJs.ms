// nim-guard: a bare read of a distinct over a zero-parameter function is a call on BOTH backends
//
// INVARIANT (checker autoCallIfAccessor; no reference analog — NIM-REF "Auto-call", DIVERGE-INTENTIONAL):
//   an Identifier or MemberExpr read whose type is `distinct (() => T)` and whose expected type is
//   not callable is rewritten into `x()` before any backend sees it; the call goes through the same
//   distinct peel as an explicit call, so a string payload is a fresh owned temp (destroyed at scope
//   exit), a captured accessor still reads the live value, and a loop reads it on every iteration.
//
// WHAT IT CATCHES: the rewrite missing on one backend (js prints a function, C reads garbage),
//   a doubled call on an explicit `x()`, a leaked or double-destroyed string temp from `"" + name`,
//   a widened accessor slot receiving a value instead of the closure.
//
// RED MEANS: exit != 0, or GUARD-OK missing on either lane.
//
// GUARD-JS

type Acc<T> = distinct (() => T);

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
	const box: Box = { label: name, n: n };
	const ok = acc === "ab1ab2ab3" && th() === "cd!" && explicit === 4 && widened() === 4
		&& name.length === 2 && render(box) === "cd:4";
	if (ok) {
		console.log("GUARD-OK");
	} else {
		console.log("GUARD-BAD", acc, th(), explicit, widened(), name.length, render(box));
	}
}

main();
