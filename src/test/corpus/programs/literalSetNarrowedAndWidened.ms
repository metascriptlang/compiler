// @stdout: ret=2,b param=3,b! typeof=3,b! num=2,b eq=12,b! eqRest=101,a? set=20,b! widen=number,string widenNull=number,string
// note: a number-literal set behaves as a string-literal set on one rule — returned through a wider union, read back after typeof narrowing (arithmetic, a typed local, a comparison), widened into a wider union (also a nullable one), and narrowed by strict equality to a member.

function retN(k: int32): 1 | 2 | string { return k > 0 ? 2 : "s"; }
function retS(k: int32): "a" | "b" | int32 { return k > 0 ? "b" : 5; }

function plusOne(v: 1 | 2 | string): int32 {
	if (typeof v === "number") return v + 1;
	return -1;
}
function bang(v: "a" | "b" | int32): string {
	if (typeof v === "string") return v + "!";
	return "-";
}
function asNumber(v: 1 | 2 | string): number {
	if (typeof v === "number") { const n: number = v; return n; }
	return -1;
}
function asString(v: "a" | "b" | int32): string {
	if (typeof v === "string") { const s: string = v; return s; }
	return "-";
}

function wrapN(k: 1 | 2): 1 | 2 | string { return k; }
function wrapS(k: "a" | "b"): "a" | "b" | int32 { return k; }
function wrapNNull(k: 1 | 2): 1 | 2 | string | null { return k; }
function wrapSNull(k: "a" | "b"): "a" | "b" | int32 | null { return k; }

function eqN(v: 1 | 2 | string): int32 {
	if (v === 2) return v + 10;
	if (typeof v === "string") return 0;
	return v + 100;
}
function eqS(v: "a" | "b" | int32): string {
	if (v === "b") return v + "!";
	if (typeof v === "number") return "n";
	return v + "?";
}
function setN(p: 1 | 2): int32 {
	if (p === 2) { const q: 2 = p; return q * 10; }
	const r: 1 = p;
	return r;
}
function setS(p: "a" | "b"): string {
	if (p === "b") { const q: "b" = p; return q + "!"; }
	const r: "a" = p;
	return r;
}

const rn = retN(1);
const rs = retS(1);
const a = wrapN(2);
const b = wrapS("b");
const c = wrapNNull(1);
const d = wrapSNull("a");

const parts: string[] = [];
parts.push(`ret=${rn},${rs}`);
parts.push(`param=${plusOne(2)},${bang("b")}`);
parts.push(`typeof=${plusOne(rn)},${bang(rs)}`);
parts.push(`num=${asNumber(2)},${asString("b")}`);
parts.push(`eq=${eqN(2)},${eqS("b")}`);
parts.push(`eqRest=${eqN(1)},${eqS("a")}`);
parts.push(`set=${setN(2)},${setS("b")}`);
parts.push(`widen=${typeof a},${typeof b}`);
parts.push(`widenNull=${c != null ? typeof c : "null"},${d != null ? typeof d : "null"}`);
console.log(parts.join(" "));
