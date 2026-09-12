// bug145 — a literal argument never took its contextual type from a union formal
// Symptom: with `Setter<T> = (v: T | ((prev: T) => T)) => void`, `setCount(c => c + 1)` failed with "got function,
//          expected int32 | function" (the arrow's parameter stayed untyped) and `setItems([1, 2])` on a
//          `number[]` signal failed with "got int32[], expected number[] | function" (the literal defaulted to int32).
// Root cause: checkAnonymousFunction/padLiteralParams and the ArrayLiteral arm peeled only a Maybe carrier
//             (`fn | null`, `T[] | null`) before looking for the function or array they type the literal from;
//             any other union formal fell through to no contextual type.
// Fix: a union formal that holds exactly one member of the literal's kind (function, array) hands that member
//      down as the contextual type, the same one-step peel the Maybe carrier already had.

type Setter145<T> = (v: T | ((prev: T) => T)) => void;

function cell145<T>(init: T): [() => T, Setter145<T>] {
	let cur: T = init;
	return [
		() => cur,
		(v: T | ((prev: T) => T)) => {
			if (typeof v === "function") { cur = v(cur); } else { cur = v; }
		},
	];
}

test "an unannotated updater arrow reaches an int32 cell" {
	const [get, set] = cell145<int32>(0);
	set(c => c + 1);
	assert get() == 1;
	set(5);
	set(c => c * 10);
	assert get() == 50;
}

test "an array cell takes an array literal and an updater" {
	const [get, set] = cell145<number[]>([]);
	set([1, 2]);
	assert get().length == 2;
	set(prev => [prev.length, prev.length, prev.length]);
	assert get().length == 3;
	assert get()[0] == 2;
	set([]);
	assert get().length == 0;
}

test "a string cell takes a literal and a capturing updater" {
	const [get, set] = cell145<string>("a");
	set("b");
	assert get() == "b";
	const suffix = "!";
	set(s => s + suffix);
	assert get() == "b!";
}
