// @stdout: ternary=b first=a second=b num=7 local=b param=a,b alias=b nested=a,b,9 float=y bool=true,x,3 set=b match=1,2,0 logged=b
// note: string literals stored in a union beside a non-string member all share its one string slot, so each reads back as itself after `typeof` narrowing — through a return, a ternary, a parameter, a typed local, an alias, a nested alias, a literal-union value, a match, and console.log.

type Key = "a" | "b";
type Slot = "a" | "b" | int32;
type Nested = Key | int32;

function show(v: "a" | "b" | int32): string {
	if (typeof v === "string") { return v; }
	return `${v}`;
}

function pick(k: int32): "a" | "b" | int32 { return k > 0 ? "b" : k; }
function first(): "a" | "b" | int32 { return "a"; }
function second(): "a" | "b" | int32 { return "b"; }
function num(): "a" | "b" | int32 { return 7; }
function viaAlias(): Slot { return "b"; }
function nested(k: int32): Nested {
	if (k == 0) { return "a"; }
	if (k == 1) { return "b"; }
	return k;
}
function showNested(v: Nested): string {
	if (typeof v === "string") { return v; }
	return `${v}`;
}
function fromSet(k: Key): Nested { return k; }
function fl(): "x" | "y" | float64 { return "y"; }
function showFl(v: "x" | "y" | float64): string {
	if (typeof v === "string") { return v; }
	return `${v}`;
}
function bl(k: int32): true | "x" | int32 {
	if (k == 0) { return true; }
	if (k == 1) { return "x"; }
	return k;
}
function showBl(v: true | "x" | int32): string {
	if (typeof v === "boolean") { return v ? "true" : "false"; }
	if (typeof v === "string") { return v; }
	return `${v}`;
}
function arm(v: "a" | "b" | int32): int32 {
	if (typeof v === "string") { return match (v) { "a" => 1, "b" => 2 }; }
	return 0;
}

const local: "a" | "b" | int32 = "b";
const out: string[] = [];
out.push("ternary=" + show(pick(1)));
out.push("first=" + show(first()));
out.push("second=" + show(second()));
out.push("num=" + show(num()));
out.push("local=" + show(local));
out.push("param=" + show("a") + "," + show("b"));
out.push("alias=" + show(viaAlias()));
out.push("nested=" + showNested(nested(0)) + "," + showNested(nested(1)) + "," + showNested(nested(9)));
out.push("float=" + showFl(fl()));
out.push("bool=" + showBl(bl(0)) + "," + showBl(bl(1)) + "," + showBl(bl(3)));
out.push("set=" + showNested(fromSet("b")));
out.push(`match=${arm("a")},${arm("b")},${arm(4)}`);
out.push("logged=");
const v = pick(1);
if (typeof v === "string") {
	const kept: Key = v;
	console.log(out.join(" ") + kept);
	console.log(v);
}
