// @stdout: declared: no
// @stdout: returned: r4 true
// @stdout: call result: c5 ok
// @stdout: discriminant only: true true
// @stdout: enum arm: a 7
// @stdout: result: 9 bad
// @stdout: value arm: pv
// @stdout: argument and element: a1 a2 true
// @stdout: sizes: 24 24 24
// note: an object converted into an arm of a by-value `match` union or of `Result` is rebuilt member by member from the arm's stored fields before codegen: the arm stores no one-value discriminator, the object stores every field, so their C structs differ. The conversion reads the object once, a call result included. Covered: a declaration, `return`, a call result, an arm holding only its discriminator, an enum-literal arm, `Result<int32, string>` from an object in both arms, a value arm, an argument, an array element and the sizes.

enum K { A, B }

struct Flag = match (ok: boolean) { true => {}, false => { error: string } };
struct Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };
struct Shape = match (kind: K) { K.A => { r: string }, K.B => { n: int32 } };

type Failure = { ok: false; error: string };

function failure(text: string): Failure { return { ok: false, error: text }; }
function textOf(f: Flag): string { return f.ok ? "ok" : f.error; }
function pairText(p: Pair): string { return p.ok ? p.value : p.error; }
function shapeText(s: Shape): string { return s.kind == K.A ? s.r : `${s.n}`; }

function declared(): string {
	const o: Failure = failure("no");
	const f: Flag = o;
	return f.ok ? "ok" : f.error;
}

function returned(n: int32): string {
	function make(): Flag {
		const o: Failure = { ok: false, error: "r" + `${n}` };
		return o;
	}
	const f = make();
	return f.ok ? "ok" : `${f.error} ${!f.ok}`;
}

function callResult(n: int32): string {
	function make(): Flag { return failure("c" + `${n}`); }
	const only: { ok: true } = { ok: true };
	const g: Flag = only;
	return `${textOf(make())} ${textOf(g)}`;
}

function discriminantOnly(): string {
	const a: { ok: true } = { ok: true };
	const f: Flag = a;
	const g: Flag = a;
	return `${f.ok} ${g.ok}`;
}

function enumArm(): string {
	const a: { kind: K.A; r: string } = { kind: K.A, r: "a" };
	const b: { kind: K.B; n: int32 } = { kind: K.B, n: 7 };
	const sa: Shape = a;
	const sb: Shape = b;
	return `${shapeText(sa)} ${shapeText(sb)}`;
}

function okResult(): Result<int32, string> {
	const o: { ok: true; value: int32 } = { ok: true, value: 9 };
	return o;
}

function errResult(): Result<int32, string> {
	const o: { ok: false; error: string } = { ok: false, error: "bad" };
	return o;
}

function resultText(): string {
	const a = okResult();
	const b = errResult();
	return `${a.ok ? a.value : -1} ${b.ok ? "none" : b.error}`;
}

function valueArm(): string {
	const o: { ok: true; value: string } = { ok: true, value: "pv" };
	const p: Pair = o;
	return pairText(p);
}

function argumentAndElement(): string {
	const a: Failure = { ok: false, error: "a1" };
	const b: Failure = { ok: false, error: "a2" };
	const only: { ok: true } = { ok: true };
	const list: Flag[] = [b, only];
	return `${textOf(a)} ${textOf(list[0])} ${list[1].ok}`;
}

console.log("declared:", declared());
console.log("returned:", returned(4));
console.log("call result:", callResult(5));
console.log("discriminant only:", discriminantOnly());
console.log("enum arm:", enumArm());
console.log("result:", resultText());
console.log("value arm:", valueArm());
console.log("argument and element:", argumentAndElement());
console.log("sizes:", sizeof(Flag), sizeof(Pair), sizeof(Shape));
