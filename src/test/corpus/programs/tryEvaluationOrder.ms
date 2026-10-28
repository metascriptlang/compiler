// @stdout: rows=34 wrong=0
// note: operands evaluate left to right around a hoisted `try`: everything written to its left runs before its operand, an error return of the `try` happens before anything to its right runs, and a value read to its left is read before the `try` operand can change it. The `await` rows are the control: the same positions with the mechanism that already orders its left operands. Each row prints only when it is wrong, with the order of operand calls it made.

let trace = "";
let rows: int32 = 0;
let wrong: int32 = 0;
function tr(s: string): void { trace = trace + s + ","; }
function g(): int32 { tr("g"); return 1; }
function k(): int32 { tr("k"); return 3; }
function gs(): string { tr("g"); return "G"; }
function ks(): string { tr("k"); return "K"; }
function h(): Result<int32, string> { tr("h"); return Result.ok(2); }
function hf(): Result<int32, string> { tr("h"); return Result.err("hf"); }
function hs(): Result<string, string> { tr("h"); return Result.ok("H"); }
function a1(): Result<int32, string> { tr("a"); return Result.ok(1); }
function af(): Result<int32, string> { tr("a"); return Result.err("af"); }
function b1(): Result<int32, string> { tr("b"); return Result.ok(2); }
async function ha(): Promise<int32> { tr("h"); return 2; }
function add(a: int32, b: int32): int32 { return a + b; }
function add3(a: int32, b: int32, c: int32): int32 { return a + b + c; }
function cat(a: string, b: string, c: string): string { return a + b + c; }
class R { f: int32 = 0; m(a: int32, b: int32): int32 { return a + b; } }
class Pair { sum: int32; constructor(a: int32, b: int32) { this.sum = a + b; } }
function recv(): R { tr("r"); return new R(); }
let arr: int32[] = [10, 20, 30];
function ga(): int32[] { tr("g"); return arr; }
let sg: int32 = 5;
function bump(): int32 { tr("g"); sg = 9; return 1; }
function c1(): boolean { tr("c"); return true; }
function c0(): boolean { tr("c"); return false; }

function call1(): Result<int32, string> { return Result.ok(add(g(), try h())); }
function call1f(): Result<int32, string> { return Result.ok(add(g(), try hf())); }
function binop(): Result<int32, string> { return Result.ok(g() + (try h())); }
function arrlit(): Result<int32, string> { const x = [g(), try h()]; return Result.ok(x[0] + x[1]); }
function objlit(): Result<int32, string> { const o = { a: g(), b: try h() }; return Result.ok(o.a + o.b); }
function method(): Result<int32, string> { return Result.ok(recv().m(g(), try h())); }
function methodf(): Result<int32, string> { return Result.ok(recv().m(g(), try hf())); }
function index(): Result<int32, string> { return Result.ok(ga()[try h()]); }
function assignIdx(): Result<int32, string> { arr[g()] = try h(); return Result.ok(arr[1]); }
function assignMember(): Result<int32, string> { recv().f = try h(); return Result.ok(1); }
function templ(): Result<string, string> { const s = `${gs()}-${try hs()}`; return Result.ok(s); }
function nested(): Result<int32, string> { return Result.ok(add(g(), add(k(), try h()))); }
function middle(): Result<int32, string> { return Result.ok(add3(g(), try h(), k())); }
function middlef(): Result<int32, string> { return Result.ok(add3(g(), try hf(), k())); }
function twoTry(): Result<int32, string> { return Result.ok(add(try a1(), try b1())); }
function twoTryf(): Result<int32, string> { return Result.ok(add(try af(), try b1())); }
function guarded(): Result<int32, string> { return Result.ok(g() + (c1() ? 0 : try h())); }
function guarded2(): Result<int32, string> { return Result.ok(g() + (c0() ? 0 : try h())); }
function snapshot(): Result<int32, string> { sg = 5; return Result.ok(sg + (try hmut())); }
function hmut(): Result<int32, string> { tr("h"); sg = 100; return Result.ok(1); }
function strs(): Result<string, string> { return Result.ok(cat(gs(), ks(), try hs())); }
function strMid(): Result<string, string> { return Result.ok(cat(gs(), try hs(), ks())); }
function ctor(): Result<int32, string> { const p = new Pair(g(), try h()); return Result.ok(p.sum); }
function compound(): Result<int32, string> { sg = 5; sg += try hmut(); return Result.ok(sg); }
function stmtLevel(): Result<int32, string> { const v = g() + k() + (try h()); return Result.ok(v); }

async function awCall(): Promise<int32> { return add(g(), await ha()); }
async function awBin(): Promise<int32> { return g() + (await ha()); }
async function awArr(): Promise<int32> { const x = [g(), await ha()]; return x[0] + x[1]; }
async function awObj(): Promise<int32> { const o = { a: g(), b: await ha() }; return o.a + o.b; }
async function awMethod(): Promise<int32> { return recv().m(g(), await ha()); }
async function awIndex(): Promise<int32> { return ga()[await ha()]; }
async function awAssign(): Promise<int32> { arr[g()] = await ha(); return arr[1]; }
async function awTempl(): Promise<string> { return `${gs()}-${await ha()}`; }
async function awNested(): Promise<int32> { return add(g(), add(k(), await ha())); }
async function awMiddle(): Promise<int32> { return add3(g(), await ha(), k()); }

function row(name: string, got: string, want: string): void {
	rows += 1;
	trace = "";
	if (got != want) { wrong += 1; console.log(`WRONG ${name}: got ${got}, want ${want}`); }
}
function ri(name: string, r: Result<int32, string>, want: string): void { row(name, `${trace} ${r.ok ? "ok" : "err"} ${r.ok ? r.value : -1}`, want); }
function rs(name: string, r: Result<string, string>, want: string): void { row(name, `${trace} ${r.ok ? "ok" : "err"} ${r.ok ? r.value : "-"}`, want); }

ri("call", call1(), "g,h, ok 3");
ri("call fails", call1f(), "g,h, err -1");
ri("binop", binop(), "g,h, ok 3");
ri("array literal", arrlit(), "g,h, ok 3");
ri("object literal", objlit(), "g,h, ok 3");
ri("method", method(), "r,g,h, ok 3");
ri("method fails", methodf(), "r,g,h, err -1");
ri("index", index(), "g,h, ok 30");
arr = [10, 20, 30];
ri("assign index", assignIdx(), "g,h, ok 2");
arr = [10, 20, 30];
ri("assign member", assignMember(), "r,h, ok 1");
rs("template", templ(), "g,h, ok G-H");
ri("nested", nested(), "g,k,h, ok 6");
ri("middle", middle(), "g,h,k, ok 6");
ri("middle fails", middlef(), "g,h, err -1");
ri("two tries", twoTry(), "a,b, ok 3");
ri("two tries first fails", twoTryf(), "a, err -1");
ri("guarded true", guarded(), "g,c, ok 1");
ri("guarded false", guarded2(), "g,c,h, ok 3");
ri("snapshot read", snapshot(), "h, ok 6");
rs("strings", strs(), "g,k,h, ok GKH");
rs("strings middle", strMid(), "g,h,k, ok GHK");
ri("constructor", ctor(), "g,h, ok 3");
ri("compound assign reads the target first", compound(), "h, ok 6");
ri("statement level", stmtLevel(), "g,k,h, ok 6");
async function main(): Promise<void> {
	const w_awCall = await awCall(); row("await call", `${trace}${w_awCall}`, "g,h,3");
	const w_awBin = await awBin(); row("await bin", `${trace}${w_awBin}`, "g,h,3");
	const w_awArr = await awArr(); row("await array", `${trace}${w_awArr}`, "g,h,3");
	const w_awObj = await awObj(); row("await object", `${trace}${w_awObj}`, "g,h,3");
	const w_awMethod = await awMethod(); row("await method", `${trace}${w_awMethod}`, "r,g,h,3");
	arr = [10, 20, 30];
	const w_awIndex = await awIndex(); row("await index", `${trace}${w_awIndex}`, "g,h,30");
	arr = [10, 20, 30];
	const w_awAssign = await awAssign(); row("await assign", `${trace}${w_awAssign}`, "g,h,2");
	const w_awTempl = await awTempl(); row("await template", `${trace}${w_awTempl}`, "g,h,G-2");
	const w_awNested = await awNested(); row("await nested", `${trace}${w_awNested}`, "g,k,h,6");
	const w_awMiddle = await awMiddle(); row("await middle", `${trace}${w_awMiddle}`, "g,h,k,6");
	console.log(`rows=${rows} wrong=${wrong}`);
}
main();
