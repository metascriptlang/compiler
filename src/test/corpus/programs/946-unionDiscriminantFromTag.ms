// @stdout: nd:seen nd:n1 pt:p2 pt:p4 pt:p2 6|nd:seen nd:n1 pt:p2 pt:p4|er:bad pt:3|a0|b:bee b|c:3 cABC|ok:5:T bad:m:F
// note: a string or boolean discriminant of a union that mixes an inline struct member with a class or interface member is read from the tag (main-reg-1: C read slot v0 and took the wrong branch or panicked).

struct Pt { kind: "pt"; x: int32; tag: string }
interface Nd { kind: "nd"; name: string }
type Mixed = Pt | Nd;
type Flipped = Nd | Pt;

class Holder { m: Mixed = { kind: "pt", x: 0, tag: "z" }; }

function mk(i: int32): Mixed {
	if (i % 2 == 0) return { kind: "pt", x: i, tag: "p" + i.toString() } as Pt;
	return { kind: "nd", name: "n" + i.toString() } as Nd;
}

function show(m: Mixed): string {
	if (m.kind === "nd") return "nd:" + m.name;
	return "pt:" + m.tag;
}

function showFlipped(m: Flipped): string {
	if (m.kind === "nd") return "nd:" + m.name;
	return "pt:" + m.tag;
}

function mixedStructInterface(): string {
	const n: Nd = { kind: "nd", name: "shared" };
	let m: Mixed = n;
	n.name = "seen";
	const arr: Mixed[] = [];
	for (let i = 0; i < 6; i += 1) arr.push(mk(i));
	const h = new Holder();
	h.m = mk(3);
	h.m = mk(4);
	const copy = arr[2];
	m = copy;
	return `${show(n)} ${show(arr[1])} ${show(copy)} ${show(h.m)} ${show(m)} ${arr.length}`;
}

function interfaceFirst(): string {
	const n: Nd = { kind: "nd", name: "shared" };
	const f: Flipped = n;
	n.name = "seen";
	const fs: Flipped[] = [f, { kind: "nd", name: "n1" } as Nd, { kind: "pt", x: 2, tag: "p2" } as Pt];
	const last: Flipped = { kind: "pt", x: 4, tag: "p4" } as Pt;
	return `${showFlipped(fs[0])} ${showFlipped(fs[1])} ${showFlipped(fs[2])} ${showFlipped(last)}`;
}

struct Ok3 { ok: true; x: int32 }
interface Er { ok: false; msg: string }
type Res = Ok3 | Er;

function showRes(r: Res): string {
	if (r.ok) return "pt:" + r.x.toString();
	return "er:" + r.msg;
}

function booleanDiscriminant(): string {
	const e: Er = { ok: false, msg: "bad" };
	const a: Res = e;
	const b: Res = { ok: true, x: 3 } as Ok3;
	return `${showRes(a)} ${showRes(b)}`;
}

struct A { kind: "a"; x: int32 }
class B { kind: "b" = "b"; name: string = ""; }
interface C { kind: "c"; w: int32 }
type U = A | B | C;

function rest(u: U): string {
	if (u.kind === "a") return "a" + u.x.toString();
	if (u.kind === "b") return "b:" + u.name + " " + u.kind;
	return "c:" + u.w.toString() + " " + u.kind;
}

function letter(u: U): string {
	switch (u.kind) {
		case "a": return "A";
		case "b": return "B";
		default: return "C";
	}
}

function threeVariants(): string {
	const b = new B();
	b.name = "bee";
	const us: U[] = [{ kind: "a", x: 0 } as A, b, { kind: "c", w: 3 } as C];
	const out: string[] = [];
	for (const u of us) out.push(rest(u));
	return out.join("|") + letter(us[0]) + letter(us[1]) + letter(us[2]);
}

interface OkI { ok: true; v: int32 }
struct Bad { ok: false; msg: string }

function showInline(r: OkI | Bad): string {
	if (!r.ok) return "bad:" + r.msg + ":" + (r.ok ? "T" : "F");
	return "ok:" + r.v.toString() + ":" + (r.ok ? "T" : "F");
}

function inlineBoolean(): string {
	const a: OkI = { ok: true, v: 5 };
	return `${showInline(a)} ${showInline({ ok: false, msg: "m" } as Bad)}`;
}

function main(): void {
	console.log([mixedStructInterface(), interfaceFirst(), booleanDiscriminant(), threeVariants(), inlineBoolean()].join("|"));
}
main();
