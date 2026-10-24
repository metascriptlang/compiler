// @xfail(raiser): raiser runtime error: expected an object, got value kind Array (inbox 2026-10-18-raiser-length-assign-on-typed-array-expects-object)
// @stdout: borrowed-source-written global=28:cfg: global=29:cfg: captured=28:cfg: captured=29:cfg: element=28:cfg: element=29:cfg: truncated=28:cfg: spliced=29:cfg: grown=28:cfg: constructs=28:cfg: initializes=29:cfg: array=3:7 array=3:13 transitive=28:cfg: transitive=29:cfg: method=28:cfg: method=29:cfg: closure=28:cfg: closure=31:axxx hook=22:valu ref=22:valu struct=25:firs struct=26:seco cursorCall=31:axxx cursorAssign=41:zqqq
let out = "borrowed-source-written";
function report(name: string, text: string): void { out += ` ${name}=${text.length}:${text.substring(0, 4)}`; }

let notice = "";
function global(text: string): void {
	notice = text + "y";
	report("global", text);
}
global(`cfg:${"x".repeat(24)}`);
global(notice);

function captured(): void {
	let held = "";
	const show = (text: string): void => {
		held = text + "y";
		report("captured", text);
	};
	show(`cfg:${"x".repeat(24)}`);
	show(held);
}
captured();

const slots: string[] = [""];
function element(text: string): void {
	slots[0] = text + "y";
	report("element", text);
}
element(`cfg:${"x".repeat(24)}`);
element(slots[0]);

function truncated(a: string[], s: string): void { a.length = 0; report("truncated", s); }
function spliced(a: string[], s: string): void { a.splice(0, 1); report("spliced", s); }
function containers(): void {
	const texts: string[] = [`cfg:${"x".repeat(24)}`];
	truncated(texts, texts[0]);
	texts.push(`cfg:${"y".repeat(25)}`);
	spliced(texts, texts[0]);
}
containers();

struct Row { name: string; tag: string; n: int64; m: int64; }
function grown(rows: Row[], r: Row): void {
	for (let i = 0; i < 2000; i += 1) rows.push({ name: "n" + i.toString(), tag: "t", n: 1, m: 2 });
	report("grown", r.name);
}
function growth(): void {
	const rows: Row[] = [{ name: `cfg:${"x".repeat(24)}`, tag: "t", n: 1, m: 2 }];
	grown(rows, rows[0]);
}
growth();

let built = `cfg:${"x".repeat(24)}`;
class Builder { n: int32 = 0; constructor() { built = "b" + "q".repeat(30); } }
class Outer { inner: Builder = new Builder(); }
function constructs(s: string): void { const b = new Builder(); report("constructs", s); }
function initializes(s: string): void { const o = new Outer(); report("initializes", s); }
constructs(built);
built = `cfg:${"y".repeat(25)}`;
initializes(built);

let numbers: number[] = [];
function array(a: number[]): void {
	numbers = [a.length + 10, 2, 3];
	out += ` array=${a.length}:${a[0]}`;
}
array([7, 8, 9]);
array(numbers);

let stamped = "";
function stamp(t: string): void { stamped = t + "y"; }
function transitive(text: string): void {
	stamp(text);
	report("transitive", text);
}
transitive(`cfg:${"x".repeat(24)}`);
transitive(stamped);

class Box {
	s: string = "";
	set(text: string): void {
		this.s = text + "y";
		report("method", text);
	}
}
const box = new Box();
box.set(`cfg:${"x".repeat(24)}`);
box.set(box.s);

let called = "";
function closure(text: string, f: () => void): void {
	f();
	report("closure", text);
}
closure(`cfg:${"x".repeat(24)}`, (): void => { called = "a" + "x".repeat(30); });
closure(called, (): void => { called = "b" + "x".repeat(30); });

let hooked: string = "value-" + (1).toString() + "-heap-heap-heap";
class Res { id: int32; constructor(id: int32) { this.id = id; } onDestroy(): void { hooked = "other-" + this.id.toString() + "-padpadpadpad"; } }
let holder: Res | null = new Res(1);
function hook(s: string): void { holder = null; report("hook", s); }
hook(hooked);

function rewrite(ref s: string, keep: string): void { s = "other-" + s.length.toString() + "-padpadpadpadpad"; report("ref", keep); }
function viaRef(p: string): void { rewrite(p, p); }
viaRef("value-" + (1).toString() + "-heap-heap-heap");

struct P { name: string; tag: string; n: int64; }
class Holder { p: P = { name: "first" + "x".repeat(20), tag: "t", n: 1 }; }
let gholder = new Holder();
function struct(p: P): void {
	gholder = new Holder();
	gholder.p = { name: "second" + "x".repeat(20), tag: "u", n: 2 };
	report("struct", p.name);
}
struct(gholder.p);
struct(gholder.p);

class Cell { s: string = ""; }
const gcell = new Cell();
gcell.s = "a" + "x".repeat(30);
function overwrite(): void { gcell.s = "z" + "q".repeat(40); }
function cursorCall(c: Cell): void {
	const t = c.s;
	overwrite();
	report("cursorCall", t);
}
cursorCall(gcell);
function cursorAssign(c: Cell): void {
	const t = c.s;
	gcell.s = "b" + "q".repeat(40);
	report("cursorAssign", t);
}
cursorAssign(gcell);

console.log(out);
