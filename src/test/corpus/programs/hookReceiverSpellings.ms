// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its @stdout line)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: hooks value=1 ref=2 var=3

struct ByValue { id: int32; name: string; }
struct ByRef { id: int32; name: string; }
struct ByVar { id: int32; name: string; }
struct ByView { id: int32; name: string; }
class ClsValue { id: int32 = 4; name: string = "k"; }
class ClsView { id: int32 = 7; name: string = "k"; }
type Shape = { kind: "a", text: string } | { kind: "b", count: int32 };
struct WriterRef { id: int32; name: string; }
struct WriterVar { id: int32; name: string; }

let valueCalls: int32 = 0;
let refCalls: int32 = 0;
let varCalls: int32 = 0;
let viewCalls: int32 = 0;
let clsCalls: int32 = 0;
let shapeCalls: int32 = 0;
let refCopy: int32 = 0;
let refMove: int32 = 0;
let refMoved: int32 = 0;
let varCopy: int32 = 0;
let varMove: int32 = 0;
let varMoved: int32 = 0;

function onDestroy(this self: ByValue): void { valueCalls += self.id; }
function onDestroy(this ref self: ByRef): void { refCalls += self.id; }
function onDestroy(this self: Var<ByVar>): void { varCalls += self.id; }
function onDestroy(this self: Readonly<ByView>): void { viewCalls += self.id; }
function onDestroy(this self: ClsValue): void { clsCalls += self.id; }
function onDestroy(this self: Readonly<ClsView>): void { clsCalls += self.id; }
function onDestroy(this self: Shape): void { shapeCalls += 1; }

function onCopy(this ref dest: WriterRef, src: WriterRef): void { refCopy += 1; dest.id = src.id; dest.name = src.name; }
function onMove(this ref dest: WriterRef, src: WriterRef): void { refMove += 1; dest.id = src.id; dest.name = src.name; }
function onMoved(this ref self: WriterRef): void { refMoved += 1; }
function onCopy(this dest: Var<WriterVar>, src: WriterVar): void { varCopy += 1; dest.id = src.id; dest.name = src.name; }
function onMove(this dest: Var<WriterVar>, src: WriterVar): void { varMove += 1; dest.id = src.id; dest.name = src.name; }
function onMoved(this self: Var<WriterVar>): void { varMoved += 1; }

function mkRef(i: int32): WriterRef { return { id: i, name: "r" + i.toString() }; }
function mkVar(i: int32): WriterVar { return { id: i, name: "v" + i.toString() }; }

function destroyed(): void {
	const a: ByValue = { id: 1, name: "a" };
	const b: ByRef = { id: 2, name: "b" };
	const c: ByVar = { id: 3, name: "c" };
	const d: ByView = { id: 4, name: "d" };
	const e = new ClsValue();
	const h = new ClsView();
	const s: Shape = { kind: "a", text: "t" };
	console.log(a.name + b.name + c.name + d.name + e.name + h.name);
}

function written(): void {
	const a: WriterRef = mkRef(1);
	let b: WriterRef = mkRef(2);
	b = a;
	b = mkRef(3);
	const c: WriterVar = mkVar(1);
	let d: WriterVar = mkVar(2);
	d = c;
	d = mkVar(3);
	console.log(a.name + b.name + c.name + d.name);
}

destroyed();
written();
console.log("hooks value=" + valueCalls.toString() + " ref=" + refCalls.toString() + " var=" + varCalls.toString());
console.log("view=" + viewCalls.toString() + " classes=" + clsCalls.toString() + " shape=" + shapeCalls.toString());
console.log("ref copy=" + refCopy.toString() + " move=" + refMove.toString() + " moved=" + refMoved.toString());
console.log("var copy=" + varCopy.toString() + " move=" + varMove.toString() + " moved=" + varMoved.toString());
