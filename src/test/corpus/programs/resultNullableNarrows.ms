// Parity program — a `Result<T, E> | null` and a generic or plain discriminated union
// `| null` carry the union by value inside the nullable wrapper, so `x !== null && x.ok`
// narrows to the union and reads its discriminant: from a ternary, a function return, a
// reassignment, an error variant and `?.ok`.
//
// @stdout: tern:kay|tern:out|ret:3|ret:none|err:bad|opt:true|opt:null|set:7|alias:5|alias:none|plain:9|plain:none
// @exit: 0

interface Me { name: string; }

type Pair<T, E> = { ok: true, value: T } | { ok: false, error: E };
type Plain = { ok: true, value: int32 } | { ok: false, error: string };

function viaTernary(good: boolean): string {
	const me = good ? JSON.parse<Me>("{\"name\":\"kay\"}") : null;
	if (me !== null && me.ok) return "tern:" + me.value.name;
	return "tern:out";
}

function viaReturn(keep: boolean): Result<int32, string> | null {
	if (keep) return Result.ok<int32, string>(3);
	return null;
}

function failing(): Result<int32, string> | null {
	return Result.err<int32, string>("bad");
}

function aliasOf(g: boolean): Pair<int32, string> | null {
	if (g) return good();
	return null;
}

function good(): Pair<int32, string> {
	return { ok: true, value: 5 };
}

function plainOf(g: boolean): Plain | null {
	return g ? { ok: true, value: 9 } : null;
}

const out: string[] = [];
out.push(viaTernary(true));
out.push(viaTernary(false));

const kept = viaReturn(true);
out.push(kept !== null && kept.ok ? "ret:" + kept.value : "ret:none");
const dropped = viaReturn(false);
out.push(dropped !== null && dropped.ok ? "ret:" + dropped.value : "ret:none");

const bad = failing();
out.push(bad !== null && !bad.ok ? "err:" + bad.error : "err:none");

out.push("opt:" + (kept?.ok ?? "null"));
out.push("opt:" + (dropped?.ok ?? "null"));

let slot: Result<int32, string> | null = null;
slot = Result.ok<int32, string>(7);
if (slot !== null) {
	const r = slot;
	if (r.ok) out.push("set:" + r.value);
}

const a = aliasOf(true);
out.push(a !== null && a.ok ? "alias:" + a.value : "alias:none");
const b = aliasOf(false);
out.push(b !== null && b.ok ? "alias:" + b.value : "alias:none");

const p = plainOf(true);
out.push(p !== null && p.ok ? "plain:" + p.value : "plain:none");
const q = plainOf(false);
out.push(q !== null && q.ok ? "plain:" + q.value : "plain:none");

console.log(out.join("|"));
