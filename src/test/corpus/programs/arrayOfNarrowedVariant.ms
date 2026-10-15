// An array literal of a narrowed `match` variant: the element is the variant's own struct.
// Axes: the ok variant and the error variant, a number payload and a string payload, a
// non-narrowed anonymous struct element, and a Result narrowed by `if (p.ok)` into an array literal.
//
// @stdout: 2 hello
// @stdout: 1 bad
// @stdout: 2 7
// @stdout: 1 1
// @stdout: 2 true
// @exit: 0

type StrRes = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
};

type NumRes = match (ok: boolean) {
	true => { value: int32 },
	false => { error: string },
};

function makeStr(s: string, isOk: boolean): StrRes {
	if (isOk) return { ok: true, value: s };
	return { ok: false, error: s };
}

function makeNum(n: int32, isOk: boolean): NumRes {
	if (isOk) return { ok: true, value: n };
	return { ok: false, error: "bad" };
}

function makeResult(n: int32): Result<int32, string> {
	if (n < 0) return Result.err("bad");
	return Result.ok(n);
}

const r = makeStr("hello", true);
if (r.ok) {
	const kept = [r, r];
	console.log(kept.length, kept[1].value);
}

const e = makeStr("bad", false);
if (!e.ok) {
	const kept = [e];
	console.log(kept.length, kept[0].error);
}

const n = makeNum(7, true);
if (n.ok) {
	const kept = [n, n];
	console.log(kept.length, kept[1].value);
}

const plain = [{ x: 1, s: "a" }];
console.log(plain.length, plain[0].x);

const p = makeResult(3);
if (p.ok) {
	const kept = [p, p];
	console.log(kept.length, kept[1].ok);
}
