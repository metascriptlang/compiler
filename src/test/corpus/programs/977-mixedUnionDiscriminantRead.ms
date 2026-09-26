// @stdout: A B A B|a b|1 2|pt nd pt nd|true false|3 n
// The discriminant of a union that mixes an inline struct with an interface reads from the tag with
// no narrowing: an enum discriminant through an alias in either variant order, through an unaliased
// union and in a match, a string one through an alias and an unaliased union, a boolean one. A
// shared field that is not the discriminant reads after narrowing. The checker refused the enum
// discriminant read ("stored inline in some variants ... behind a reference in others").

enum K { A, B }
interface Bv { kind: K.B; y: int32; name: string }
struct Av { kind: K.A; x: int32; name: string }
type BA = Bv | Av;
type AB = Av | Bv;

interface Nd { kind: "nd"; name: string }
struct Pt { kind: "pt"; x: int32 }
type Shape = Pt | Nd;

struct Ok { ok: true; v: int32 }
interface Er { ok: false; msg: string }
type Res = Ok | Er;

function nameBA(e: BA): string { return e.kind === K.A ? "A" : "B"; }
function nameAB(e: AB): string { return e.kind == K.A ? "A" : "B"; }
function nameInline(e: Bv | Av): string { return match (e.kind) { K.A => "a", K.B => "b" }; }
function num(e: BA): int32 {
	if (e.kind === K.A) return e.x;
	return e.y;
}
function shapeTag(s: Shape): string { return s.kind; }
function isOk(r: Res): boolean { return r.ok; }
function shapeInline(s: Nd | Pt): string { return s.kind == "pt" ? "pt" : "nd"; }
function label(e: BA): string {
	if (e.kind === K.B) return e.name;
	return e.name;
}

function run(): void {
	const a: Av = { kind: K.A, x: 1, name: "3" };
	const b: Bv = { kind: K.B, y: 2, name: "n" };
	console.log(nameBA(a), nameBA(b), nameAB(a), nameAB(b));
	console.log(nameInline(a), nameInline(b));
	console.log(num(a), num(b));
	const p: Pt = { kind: "pt", x: 4 };
	const n: Nd = { kind: "nd", name: "q" };
	console.log(shapeTag(p), shapeTag(n), shapeInline(p), shapeInline(n));
	const ok: Res = { ok: true, v: 5 } as Ok;
	const er: Res = { ok: false, msg: "bad" } as Er;
	console.log(isOk(ok), isOk(er));
	console.log(label(a), label(b));
}
run();
