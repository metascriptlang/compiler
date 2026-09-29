// Symptom: on JS `a == b` with `a: S | null` and a struct `S` compared the two objects by reference, so equal values answered false and `!=` true; C was right.
// Root cause: operatorLower sent a nullable comparison to the carrier's Eq on C only; JS holds the payload or null and fell through to `===`.
// Fix: a nullable value payload calls the carrier's Eq on JS too, whose body compares as Nim's Option `==` (options.nim:350); a primitive payload keeps `===`.
// Runtime on every lane: corpus 665.
import { compileToJS } from "../helpers";

const SRC = `
struct In { a: int32; s: string; }
function same(x: In | null, y: In | null): boolean { return x == y; }
function samePayload(p: In | null, q: In): boolean { return p == q; }
function sameInt(m: int32 | null, n: int32 | null): boolean { return m == n; }
const v: In = { a: 1, s: "k" };
console.log(same(v, v), samePayload(v, v), sameInt(1, 1));
`;

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
		|| c == "_" || c == "$";
}

function calleeOf(out: string, args: string): string {
	const at = out.indexOf(args, 0);
	if (at < 0) return "";
	let start = at;
	while (start > 0) {
		if (!isIdentChar(out.charAt(start - 1))) break;
		start -= 1;
	}
	return out.slice(start, at);
}

function comparedByEq(out: string, args: string): string {
	const callee = calleeOf(out, args);
	if (!callee.endsWith("Eq")) return `${args} calls '${callee}'; `;
	if (out.indexOf("function " + callee + "(", 0) < 0) return `'${callee}' is not defined; `;
	return "";
}

test "bug628: a nullable struct compares through its carrier's Eq (JS)" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const failure = comparedByEq(r.value, "(x, y);") + comparedByEq(r.value, "(p, q);");
		assert failure == "", failure;
	}
}

test "bug628: a nullable primitive still compares with === (JS)" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		assert r.value.indexOf("m === n", 0) >= 0, r.value;
	}
}
