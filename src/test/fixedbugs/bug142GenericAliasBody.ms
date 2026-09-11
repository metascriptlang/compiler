// bug142 — a generic alias over a function, array or tuple type had no instantiated body
// Symptom: `type Setter<T> = (v: T) => void; const s: Setter<int32> = …` reached clang as "unknown type name
//          'Setter__int32'"; the same alias as an interface field was rejected by the checker ("Type 'function'
//          is not assignable to type 'Setter' for field"); `type Box<T> = T[]` returned from a generic function
//          failed with "expected <kind:Ref>, got int32[]".
// Root cause: instantiateGenericBody substituted only Struct/Union/Conditional/GenericParam/GenericInstance
//             bodies, so every other body kind left the instance without a typeReturn and nothing downstream
//             could peel it (the reference instantiates the body of a generic invocation whatever its kind).
// Fix: instantiate every body kind except a distinct (which stays nominal), keep a non-nominal Ref inside the
//      instance body, and read through the instance at every consumer that switches on the body's kind.

type Setter142<T> = (v: T) => void;
type Box142<T> = T[];
type Pair142<T> = [T, T];
type Phantom142<T> = int32;
type Same142<T> = T;
interface Cell142<T> { set: Setter142<T>; }

function mk142<T>(init: T): [() => T, Setter142<T>] {
	let cur: T = init;
	return [() => cur, (v: T) => { cur = v; }];
}

function wrap142<T>(x: T): Box142<T> { return [x]; }
function pair142<T>(x: T): Pair142<T> { return [x, x]; }

test "a generic alias over a function type is a callable variable" {
	let got: int32 = 0;
	const s: Setter142<int32> = (v: int32) => { got = v; };
	s(5);
	assert got == 5;
}

test "a generic alias over a function type returns in a tuple from a generic function" {
	const [get, set] = mk142<int32>(1);
	set(7);
	assert get() == 7;
}

test "a generic alias over a function type is an interface field" {
	let got: int32 = 0;
	const c: Cell142<int32> = { set: (v: int32) => { got = v; } };
	c.set(9);
	assert got == 9;
}

test "a generic alias over a function type copies through a struct and an array" {
	let got: int32 = 0;
	const c: Cell142<int32> = { set: (v: int32) => { got = got + v; } };
	const d = c;
	const arr: Setter142<int32>[] = [c.set, d.set];
	for (const f of arr) f(2);
	assert got == 4;
}

test "a generic alias over an array type returns from a generic function" {
	const xs: Box142<int32> = wrap142<int32>(3);
	assert xs.length == 1;
	assert xs[0] == 3;
}

test "a generic alias over a tuple type indexes to the element" {
	const p: Pair142<int32> = pair142<int32>(4);
	assert p[0] + p[1] == 8;
}

test "a generic alias over a primitive stringifies as its value and adds as a number" {
	const x: Phantom142<boolean> = 3;
	assert x.toString() == "3";
	assert (x + 1).toString() == "4";
	const y: Same142<string> = "hi";
	assert y.length == 2;
	assert y.toString() == "hi";
}
