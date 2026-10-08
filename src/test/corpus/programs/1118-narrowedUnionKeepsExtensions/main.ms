// @stdout: 4 -1|circle 3|square 2
// note: a binding narrowed to one variant of a union is still a value of that union, so the
// union's extensions take it (TS keeps a narrowed value assignable to its declared type). The
// narrowed-variant member check used to refuse every name that was not a field of the variant.
import { JsonKind, JsonValue } from "std/serialize/json/types";

type Shape = { kind: "circle"; r: int32 } | { kind: "square"; side: int32 };
function label(this s: Shape): string { return s.kind == "circle" ? `circle ${s.r}` : `square ${s.side}`; }

function first(v: JsonValue): number {
	if (v.kind == JsonKind.Array) return v.at(0).asNumber();
	return -1;
}
function describe(s: Shape): string {
	if (s.kind == "circle") return s.label();
	return s.label();
}
const out: string[] = [];
const parsed = JSON.parseValue("[4, 5]");
const scalar = JSON.parseValue("7");
if (parsed.ok && scalar.ok) out.push(`${first(parsed.value)} ${first(scalar.value)}`);
out.push(describe({ kind: "circle", r: 3 }));
out.push(describe({ kind: "square", side: 2 }));
console.log(out.join("|"));
