// @stdout: differs: none
let g: int32 = 0;
let gs: string = "a";
class Box { n: int32 = 0; }
struct Pt { x: int32; y: int32; }
const box = new Box();
const seen: string[] = [];
function show(line: string): int32 { console.log(line); seen.push(line); return 1; }
let pt: Pt = { x: 1, y: 1 };
function bump(): int32 { g += 1; return 10; }
function bumpBox(b: Box): int32 { b.n += 1; return 10; }
function bumpS(): int32 { gs = gs + "b"; return 10; }
function bumpPt(): int32 { pt.x += 1; return 10; }
function pair(tag: string, a: int32, b: int32): int32 { return show(`${tag}: ${a} ${b}`); }
function pairS(tag: string, a: string, b: int32): int32 { return show(`${tag}: ${a} ${b}`); }
function pairP(tag: string, a: Pt, b: int32): int32 { return show(`${tag}: ${a.x} ${b}`); }

pair("statement global", g, bump());
pair("statement field", box.n, bumpBox(box));
pairS("statement string", gs, bumpS());
pair("statement operator", g + 1, bump());
pair("statement struct field", pt.x, bumpPt());
pairP("whole struct", pt, bumpPt());
const d = pair("declaration", g, bump());
const r = ((): int32 => { return pair("return", box.n, bumpBox(box)); })();
if (pair("condition global", g, bump()) > 0) { show("then"); }
if (pair("condition field", box.n, bumpBox(box)) > 0) { show("then"); }
if (pairS("condition string", gs, bumpS()) > 0) { show("then"); }
let k: int32 = 0;
const inc = (): int32 => { k += 1; return 10; };
pair("captured local", k, inc());
pair("nested outer", g, pair("nested inner", g, bump()) + bump());
show(`end ${g} ${box.n} ${gs} ${pt.x} ${k} ${d + r}`);
const expected: string[] = [
	"statement global: 0 10", "statement field: 0 10", "statement string: a 10", "statement operator: 2 10",
	"statement struct field: 1 10", "whole struct: 3 10", "declaration: 2 10", "return: 1 10",
	"condition global: 3 10", "then", "condition field: 2 10", "then", "condition string: ab 10", "then",
	"captured local: 0 10", "nested inner: 4 10", "nested outer: 4 11", "end 6 3 abb 3 1 2",
];
const off: string[] = [];
for (let i = 0; i < expected.length; i++) {
	if (i >= seen.length || seen[i] != expected[i]) off.push(expected[i]);
}
if (seen.length != expected.length) off.push(`${seen.length} lines`);
console.log(`differs: ${off.length == 0 ? "none" : off.join(" | ")}`);
