// Symptom: `T | null` with a fixed array, a tuple, a generic struct instance or a `Vec<T>` payload failed at clang on C wherever it was declared, assigned, read or compared (`msUnion_* ... where arithmetic or pointer type is required`); JS compared by reference and a nullable parameter compared with null answered false; `{ v: 4 }` into `Box<int32> | null` was a checker error.
// Root cause: nullableUnionOf wrapped only structs, primitives, strings and functions into the `{ value, present }` carrier; these payloads stayed a plain union with no null test. The object literal against a nullable instance was stamped with the instance's body struct instead of the instance.
// Fix: every value payload wraps into the carrier, as Nim's `Option[T]` keeps `has` for every T that is not a pointer (options.nim:91-99); the literal is stamped with the carrier's payload.
// Runtime on every lane: corpus 668.
import { compileToC } from "../helpers";

function emitFor(payload: string, value: string): string {
	const r = compileToC(`
struct Box<T> { v: T; }
function isNull(a: ${payload} | null): boolean { return a == null; }
const x: ${payload} | null = ${value};
console.log(isNull(x), isNull(null));
`);
	return r.ok ? r.value : "error: " + r.error;
}

test "bug632: a nullable fixed array, tuple, generic instance or Vec is a Maybe carrier (C)" {
	const outs = [
		emitFor("uint8[4]", "[1, 2, 3, 4]"),
		emitFor("[int32, string]", "[1, \"a\"]"),
		emitFor("Box<int32>", "{ v: 4 }"),
		emitFor("Vec<int32>", "null"),
	];
	for (const out of outs) {
		assert out.indexOf("error:", 0) < 0, out;
		assert out.indexOf("Maybe_", 0) >= 0 && out.indexOf("msUnion_", 0) < 0, out;
		assert out.indexOf(".present", 0) >= 0, out;
	}
}
