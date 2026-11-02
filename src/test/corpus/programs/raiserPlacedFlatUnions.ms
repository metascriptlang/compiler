// @stdout: ok 3 err boom node 7 pair 2 shape a:t b:4
// note: a union of struct arms is the member's own cell, and a union of class refs the member's handle, so each is released as one cell and not through the tag layout the C union uses.

class N { k: int32 = 0; }
type Num = { ok: true, value: number } | { ok: false, error: string };
type Pair = { node: N, pos: int32 };
type Shape = { kind: "a", text: string } | { kind: "b", count: int32 };

function num(good: boolean): Num {
	if (good) return { ok: true, value: 3 };
	return { ok: false, error: "boom" };
}
function viaResult(): Result<N, string> { const n = new N(); n.k = 7; return Result.ok(n); }
function viaPair(): Result<Pair, string> { return Result.ok({ node: new N(), pos: 2 }); }
function describe(s: Shape): string {
	if (s.kind == "a") return "a:" + s.text;
	return "b:" + s.count.toString();
}

const good = num(true);
const bad = num(false);
const r = viaResult();
const p = viaPair();
const out: string[] = [];
if (good.ok) out.push("ok " + good.value.toString());
if (!bad.ok) out.push("err " + bad.error);
if (r.ok) out.push("node " + r.value.k.toString());
if (p.ok) out.push("pair " + p.value.pos.toString());
out.push("shape " + describe({ kind: "a", text: "t" }) + " " + describe({ kind: "b", count: 4 }));
console.log(out.join(" "));
