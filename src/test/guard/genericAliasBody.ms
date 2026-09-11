// nim-guard: a generic alias over a function, array or tuple type is its substituted body on BOTH backends
//
// INVARIANT (reference handleGenericInvocation instantiates the body of a generic invocation
//   whatever its kind, and every consumer skips tyGenericInst to reach it): `Setter<int32>` is
//   the closure `(v: int32) => void` at the C ABI, in a struct field, in an array and in a tuple
//   returned from a generic function; `Box<int32>` is `int32[]`; `Pair<int32>` is `[int32, int32]`.
//
// WHAT IT CATCHES: C naming a struct `Setter__int32` that nothing defines, hook names spelled
//   after the alias instance, the checker refusing the alias as a field type, or the js lane
//   regressing while native passes.
//
// RED MEANS: exit != 0, or GUARD-OK missing on either lane.
//
// GUARD-JS

type Setter<T> = (v: T) => void;
type Box<T> = T[];
type Pair<T> = [T, T];
interface Cell<T> { set: Setter<T>; }

function mk<T>(init: T): [() => T, Setter<T>] {
	let cur: T = init;
	return [() => cur, (v: T) => { cur = v; }];
}
function wrap<T>(x: T): Box<T> { return [x]; }
function pair<T>(x: T): Pair<T> { return [x, x]; }

let got: int32 = 0;
const s: Setter<int32> = (v: int32) => { got = got + v; };
s(1);
const [get, set] = mk<int32>(1);
set(7);
const c: Cell<int32> = { set: s };
const d = c;
const arr: Setter<int32>[] = [c.set, d.set];
for (const f of arr) f(2);
const xs: Box<int32> = wrap<int32>(3);
const p: Pair<int32> = pair<int32>(4);
if (got == 5 && get() == 7 && xs.length == 1 && xs[0] == 3 && p[0] + p[1] == 8) {
	console.log("GUARD-OK");
} else {
	console.log("GUARD-FAIL " + got.toString() + " " + get().toString() + " " + xs.length.toString());
}
