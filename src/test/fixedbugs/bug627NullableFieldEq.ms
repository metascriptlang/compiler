// Symptom: `==` on a struct with a `T | null` field called a `Maybe_<T>Eq` nothing defined, for a primitive and a struct payload alike (C `call to undeclared function`, JS `Maybe_p10Eq is not defined`).
// Root cause: the field's Eq was looked up by the carrier's name in the module's symbol table, where a synthesized carrier never is.
// Fix: C calls the carrier's generated Eq, built from its Type as the top-level carrier comparison already was; JS, where the field holds the payload or null, compares as Nim's Option `==` does (options.nim:350): both absent, or both present with equal payloads.
// C runs in corpus 664: compileToC takes its alive set before the transform, so no generated Eq body reaches its output.
import { compileToJS } from "../helpers";

const SRC = `
struct In { a: int32; }
struct Out { n: int32 | null; opt: In | null; }
function same(x: Out, y: Out): boolean { return x == y; }
const o: Out = { n: 1, opt: { a: 2 } };
console.log(same(o, o));
`;

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
		|| c == "_" || c == "$";
}

function undefinedFieldEq(out: string, field: string): string {
	const args = `(a.${field}, b.${field})`;
	const at = out.indexOf(args, 0);
	if (at < 0) return "";
	let start = at;
	while (start > 0) {
		if (!isIdentChar(out.charAt(start - 1))) break;
		start -= 1;
	}
	const callee = out.slice(start, at);
	if (out.indexOf("function " + callee + "(", 0) >= 0) return "";
	return `${field}: '${callee}' is not defined; `;
}

test "bug627: every Eq a nullable field's comparison calls is defined (JS)" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const failure = undefinedFieldEq(r.value, "n")
			+ undefinedFieldEq(r.value, "opt");
		assert failure == "", failure;
	}
}

test "bug627: an absent nullable field equals only an absent one (JS)" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const shape = "(a.opt === b.opt) || (((a.opt !== null) && (b.opt !== null)) && ";
		assert r.value.indexOf(shape, 0) >= 0, r.value;
	}
}
