// @stdout: 2.5|50%|null|5|x|null|3|6
// @xfail(js): typeof of a nullable tagged union reads the wrong member (inbox card typeof-of-a-nullable-tagged-union-is-object-on-js)
// @xfail(esm): same JS emission as the js lane
// @xfail(raiser): Raiser cannot read a union member through a host call
function lengthOf(v: float32 | int32 | string | null): float32 | string | null {
	if (typeof v === "string") { return v as string; }
	return v as float32 | null;
}

function wide(v: int32 | number | string | null): number | string | null {
	if (typeof v === "string") { return v as string; }
	return v as number | null;
}

function narrowed(v: float32 | int32 | string | null): float32 | int32 | null {
	if (v != null && typeof v != "string") { return v; }
	return null;
}

function text(v: float32 | string | null): string {
	if (v == null) return "null";
	return typeof v === "string" ? v : String(v);
}

function textW(v: number | string | null): string {
	if (v == null) return "null";
	return typeof v === "string" ? v : String(v);
}

console.log([
	text(lengthOf(2.5)),
	text(lengthOf("50%")),
	text(lengthOf(null)),
	textW(wide(5.0)),
	textW(wide("x")),
	textW(wide(null)),
	String(narrowed(3 as int32) as number),
	String(narrowed(6.0) as number)
].join("|"));
