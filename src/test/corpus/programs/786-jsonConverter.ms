// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// Parity program — a parsed JSON value reads through the JSON converters: a
// typed slot, an argument, `as U`, and an operand whose other side is typed
// (arithmetic, comparison, string concatenation).
//
// @stdout: slot Ann 41 true 1.5|arg 41|as 41|op 42 hi Ann true 3
// @exit: 0

function take(n: int32): int32 { return n; }

const r = parseJson(`{"name": "Ann", "age": 41, "ok": true, "ratio": 1.5, "a": 1, "b": 2}`);
if (r.ok) {
	const j = r.value;
	const name: string = j.name;
	const age: int32 = j.age;
	const ok: boolean = j.ok;
	const ratio: number = j.ratio;
	const arg = take(j.age);
	const cast = j.age as int32;
	const next = j.age + 1;
	const greet = "hi " + j.name;
	const older = j.age > 40;
	const sum = j.a + (j.b as int32);
	console.log(`slot ${name} ${age} ${ok} ${ratio}|arg ${arg}|as ${cast}|op ${next} ${greet} ${older} ${sum}`);
}
