// Symptom: on JS `a.push(v.intVal)` with `a: number[]` and an int64 value stored the BigInt itself, so a later `xs[a[0]]` threw "Cannot convert a BigInt value to a number" (corpus 630).
// Root cause: a `sink` parameter's type is `Sink<T>`, and the numeric conversion check compared the argument with the wrapper, not with `T`, so no widening or narrowing was inserted once the array and map externs took their value as `sink`.
// Fix: the conversion check and the conversion node read through `Sink<T>` to `T`, as they already did through `Var<T>`.
interface V243 { intVal: int64; small: int32; byte: uint8; }

test "bug243: an int64 pushed into number[] is a number" {
	const v: V243 = { intVal: 1, small: 2, byte: 3 };
	const a: number[] = [];
	a.push(v.intVal);
	const xs = ["a", "b"];
	assert xs[a[0]] == "b";
}

test "bug243: int32 and uint8 pushed into number[] and float64[]" {
	const v: V243 = { intVal: 1, small: 2, byte: 3 };
	const a: number[] = [];
	a.push(v.small);
	a.push(v.byte);
	const f: float64[] = [];
	f.push(v.intVal);
	assert a[0] + a[1] == 5;
	assert f[0] + 0.5 == 1.5;
}

test "bug243: a map value converts the same way" {
	const v: V243 = { intVal: 4, small: 2, byte: 3 };
	const m = new Map<string, number>();
	m.set("k", v.intVal);
	const xs = ["a", "b", "c", "d", "e"];
	assert xs[m.get("k")!] == "e";
}
