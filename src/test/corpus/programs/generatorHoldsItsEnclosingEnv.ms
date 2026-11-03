// @stdout: x1|x1b|x2|x2b|x3|x3b|x4|x4b|r5|r5b|x6|x6b|7|8|x8|x8b|x9b
const out: string[] = [];

class Box { v: string; constructor(v: string) { this.v = v; } }
struct R { id: int32; s: string; }
let dropped: int32 = 0;
function onDestroy(this r: R): void { if (r.id != 0) dropped += 1; }
function mk(id: int32): R { return { id: id, s: "r" + id.toString() }; }

function viaDecl(): Iterator<string> {
	const s = "x" + (1).toString();
	function* g(): Iterator<string> { yield s; yield s + "b"; }
	return g();
}
function viaExpr(): Iterator<string> {
	const s = "x" + (2).toString();
	const g = function* (): Iterator<string> { yield s; yield s + "b"; };
	return g();
}
function viaParam(s: string): Iterator<string> {
	function* g(): Iterator<string> { yield s; yield s + "b"; }
	return g();
}
function viaClass(): Iterator<string> {
	const b = new Box("x" + (4).toString());
	function* g(): Iterator<string> { yield b.v; yield b.v + "b"; }
	return g();
}
function viaStruct(): Iterator<string> {
	const r = mk(5);
	function* g(): Iterator<string> { yield r.s; yield r.s + "b"; }
	return g();
}
function viaTwoLevels(): Iterator<string> {
	const s = "x" + (6).toString();
	function mid(): Iterator<string> {
		function* g(): Iterator<string> { yield s; yield s + "b"; }
		return g();
	}
	return mid();
}
function viaNumber(): Iterator<int32> {
	const n: int32 = 6 + 1;
	function* g(): Iterator<int32> { yield n; yield n + 1; }
	return g();
}
function inScope(): void {
	const s = "x" + (8).toString();
	function* g(): Iterator<string> { yield s; yield s + "b"; }
	for (const v of g()) out.push(v);
}
function asyncTwin(): Promise<string> {
	const s = "x" + (9).toString();
	async function g(): Promise<string> { await sleepAsync(1); return s + "b"; }
	return g();
}

for (const v of viaDecl()) out.push(v);
for (const v of viaExpr()) out.push(v);
for (const v of viaParam("x" + (3).toString())) out.push(v);
for (const v of viaClass()) out.push(v);
for (const v of viaStruct()) out.push(v);
const twoLevels = viaTwoLevels();
for (let r = twoLevels.next(); !r.done; r = twoLevels.next()) out.push(r.value);
for (const v of viaNumber()) out.push(v.toString());
inScope();
out.push(await asyncTwin());
console.log(out.join("|"));
