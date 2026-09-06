// @stdout: object reflection done

// Object.keys/values — compile-time reflection over statically shaped values.
// The static generic method body defers a macro call until T is concrete
// (codec deferral pattern); the macro walks the peeled type shape and emits
// a plain array literal. Zero runtime reflection; both backends emit the
// same literal. values() requires all fields to share one atomic type.

interface Point { x: int32; y: int32; }
interface Labels { a: string; b: string; }
interface Single { only: float64; }

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function keysSurface(): boolean {
	const p: Point = { x: 3, y: 7 };
	const ks = Object.keys(p);
	let ok = check("count", ks.length == 2);
	ok = check("first", ks[0] == "x") && ok;
	ok = check("second", ks[1] == "y") && ok;
	const l: Labels = { a: "alpha", b: "beta" };
	const lk = Object.keys(l);
	ok = check("string shape", lk.length == 2 && lk[0] == "a" && lk[1] == "b") && ok;
	const s: Single = { only: 1.5 };
	const sk = Object.keys(s);
	ok = check("single field", sk.length == 1 && sk[0] == "only") && ok;
	return ok;
}

function valuesSurface(): boolean {
	const p: Point = { x: 3, y: 7 };
	const vs = Object.values(p);
	let ok = check("int values", vs.length == 2 && vs[0] == 3 && vs[1] == 7);
	const l: Labels = { a: "alpha", b: "beta" };
	const lv = Object.values(l);
	ok = check("string values", lv.length == 2 && lv[0] == "alpha" && lv[1] == "beta") && ok;
	const s: Single = { only: 2.5 };
	const sv = Object.values(s);
	ok = check("float values", sv.length == 1 && sv[0] == 2.5) && ok;
	return ok;
}

// The same deferred-macro channel must survive a generic wrapper: an
// un-annotated generic return has to reach codegen fully typed on both
// backends (this pinned a real gap: Inferred returns survived mono).
function dup<T>(x: T) { return x; }

function genericInferredReturn(): boolean {
	const n = dup<int32>(42);
	const s = dup<string>("hey");
	let ok = check("int roundtrip", n == 42);
	ok = check("string roundtrip", s == "hey") && ok;
	const joined = Object.keys({ x: 1, y: 2 } as Point);
	ok = check("inline literal shape", joined[0] == "x" && joined[1] == "y") && ok;
	return ok;
}

function main(): int32 {
	let ok = keysSurface();
	ok = valuesSurface() && ok;
	ok = genericInferredReturn() && ok;
	if (!ok) { return 1; }
	console.log("object reflection done");
	return 0;
}

main();
