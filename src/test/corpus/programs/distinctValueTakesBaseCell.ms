// @skip-js: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: 1
// @stdout: 3 2
// @stdout: 2
// @stdout: 2
// @stdout: 4 44 p44
// @stdout: 3 1
// @stdout: S destroy 2
// @stdout: made e s3
// @stdout: S destroy 3
// @stdout: true
// @stdout: 8 7
struct P { x: int32; name: string; }
type H = distinct P;
type H2 = distinct H;
struct W { h: H; }
function mkP(i: int32): P { return { x: i, name: "p" + i.toString() }; }
function mkH(i: int32): H { return mkP(i) as H; }
function take(sink h: H): int32 { return (h as P).x; }

function moveThenReassign(): void {
	const a = mkH(1);
	console.log(take(a));
	let b = mkH(2);
	const c = b;
	b = mkH(3);
	console.log((b as P).x, (c as P).x);
}

function reassignLocal(): void {
	let h: H = mkP(1) as H;
	h = mkP(2) as H;
	console.log((h as P).x);
}

function reassignField(): void {
	let w: W = { h: mkP(1) as H };
	w.h = mkP(2) as H;
	console.log((w.h as P).x);
}

function copyThenReassign(): void {
	const h: H = mkP(4) as H;
	let h2 = h;
	h2 = mkP(44) as H;
	const hp = h as P;
	const hp2 = h2 as P;
	console.log(hp.x, hp2.x, hp2.name);
}

function nestedDistinct(): void {
	let h: H2 = (mkP(1) as H) as H2;
	const k = h;
	h = (mkP(2) as H) as H2;
	h = (mkP(3) as H) as H2;
	console.log(((h as H) as P).x, ((k as H) as P).x);
}

struct S { id: int32; s: string; }
function onDestroy(this x: S): void { if (x.id != 0) console.log(`S destroy ${x.id}`); }
type E = distinct S;
function mkS(id: int32): S { return { id: id, s: "s" + id.toString() }; }

function hookedBase(): void {
	let e = mkS(2) as E;
	e = mkS(3) as E;
	console.log("made e " + (e as S).s);
}

enum Kind { A, B }
struct U = match (kind: Kind) { Kind.A => { s: string }, Kind.B => { n: int32 } };
type D = distinct U;
function mkA(): U { return { kind: Kind.A, s: "a" + "b" }; }
function mkB(n: int32): U { return { kind: Kind.B, n: n }; }

function unionArm(): void {
	let d: D = mkA() as D;
	d = mkB(3) as D;
	console.log((d as U).kind == Kind.B);
}

moveThenReassign();
reassignLocal();
reassignField();
copyThenReassign();
nestedDistinct();
hookedBase();
unionArm();

let gh: H = mkP(7) as H;
const gh2 = gh;
gh = mkP(8) as H;
console.log((gh as P).x, (gh2 as P).x);
