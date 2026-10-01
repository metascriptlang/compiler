// Symptom: a generic type written without its type arguments (`function f(this o: Owned)` with `struct Owned<T>`) passed the declaration and failed at the call ("expected Owned"); as a variable, array element or `as` target it resolved to the unparameterised body.
// Root cause: resolveAnnotation returned a bare generic name's symbol type unchecked.
// Fix: a generic type named without type arguments is an error at the annotation, as TypeScript's "Generic type 'Owned' requires 1 type argument(s)" (Nim makes a bare generic parameter an implicit generic and refuses it for a variable).
import { compileToJS } from "../helpers";

function checkError(src: string): string {
	const r = compileToJS(`struct Owned<T> { v: T; n: int32; }\ninterface Pair<K, V> { k: K; v: V; }\n${src}\n`);
	return r.ok ? "" : r.error;
}

test "bug633: a generic type without its type arguments is refused where it is written" {
	const receiver = checkError("function f(this o: Owned): int32 { return o.n; }");
	const local = checkError("const p: Pair | null = null;");
	const element = checkError("const xs: Owned[] = [];");
	assert receiver.indexOf("generic type 'Owned' requires 1 type argument(s)", 0) >= 0, receiver;
	assert local.indexOf("generic type 'Pair' requires 2 type argument(s)", 0) >= 0, local;
	assert element.indexOf("generic type 'Owned' requires 1 type argument(s)", 0) >= 0, element;
}

test "bug633: a generic type with its type arguments is accepted" {
	const ok = checkError("function f(this o: Owned<int32>): int32 { return o.n; }\nconst p: Pair<int32, string> | null = null;");
	assert ok == "", ok;
}
