// @stdout: true false 1 2
// @stdout: false 8 true 4
// note: a `T | null` argument of a scalar T read from a frame place and passed to a borrowing parameter is held in a register of its own class for the call; the Raiser VM held it in a Ref register, so a true or non-zero value faulted as a handle (exit 139, or "register is Ref, got Bool" through the embed) while false and 0 passed. Solid-style memos reach it: `(prev: T | null) => compute(prev)` inside a generic.

function build<T>(produce: (prev: T | null) => T, first: T): () => T {
	let held: T = first;
	return (): T => {
		held = produce(held);
		return held;
	};
}

function memo<T>(compute: (prev: T | null) => T, first: T): () => T {
	return build<T>((prev: T | null): T => compute(prev), first);
}

const flip = memo<boolean>((prev: boolean | null): boolean => prev === null ? true : !prev, false);
const count = memo<int32>((prev: int32 | null): int32 => prev === null ? 0 : prev + 1, 0);
console.log(`${flip()} ${flip()} ${count()} ${count()}`);

function negate(prev: boolean | null): boolean { return prev === null ? false : !prev; }
function double(prev: int32 | null): int32 { return prev === null ? 0 : prev * 2; }

function forward(compute: (prev: boolean | null) => boolean): (prev: boolean | null) => boolean {
	return (prev: boolean | null): boolean => compute(prev);
}

function direct<T>(first: T, f: (v: T | null) => T): T {
	const g = (prev: T | null): T => f(prev);
	return g(first);
}

const viaClosure = forward((prev: boolean | null): boolean => prev === null ? false : !prev);
console.log(`${viaClosure(true)} ${direct<int32>(4, double)} ${direct<boolean>(false, negate)} ${direct<int32>(2, double)}`);
