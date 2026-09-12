// bug147 — a parameter typed as a distinct over a function type was passed by pointer
// Symptom: `type Acc<T> = distinct (() => T)`; a callback declared `(a: () => number) => number` stored in a
//          slot `(a: Acc<number>) => number` (the one-way widen) read garbage when called — Neon's `<For>`
//          children `(item, i: () => number)` died in `msIncRef` (misaligned 0x8b7) once the row index became an
//          `Accessor<number>`: a function whose parameter is `Acc<number>` took `msClosure*` while its base
//          signature takes `msClosure`.
// Root cause: ccgIntroducedPtr (the pointer-parameter pass and its codegen twin) promoted EVERY GenericInstance
//             parameter that is not awaitable — a rule written for generic struct instances that also caught a
//             distinct over a function and a transparent alias such as `Setter<T>`; shouldIndirectParam then
//             classified the same instance as a struct.
// Fix: a generic instance is promoted by its representation (genericInstanceAbiRepr: the transparent body or the
//      distinct body when that is not a struct), and shouldIndirectParam / shouldConstParam read the same
//      representation.

type Acc147<T> = distinct (() => T);

function acc147<T>(f: () => T): Acc147<T> {
	return f as Acc147<T>;
}

function readThrough(a: Acc147<number>): number {
	return a() + 1;
}

test "a callback with a plain closure parameter runs through a distinct-typed slot" {
	const cb: (a: () => number) => number = (a) => a() + 1;
	const slot: (a: Acc147<number>) => number = cb;
	assert slot(acc147(() => 41)) == 42;
}

test "a function declared with the distinct parameter takes the same closure by value" {
	const viaBase: (a: () => number) => number = readThrough;
	assert viaBase(() => 9) == 10;
	assert readThrough(acc147(() => 1)) == 2;
}
