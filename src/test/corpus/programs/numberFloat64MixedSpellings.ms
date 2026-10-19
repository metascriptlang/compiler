// @stdout: 10|2|2.5|3.5|2.5|0|1.5
// @exit: 0

type Setter<T> = (v: T | ((prev: T) => T)) => void;

const seen: string[] = [];

function makeSetter<T>(init: T): Setter<T> {
	let value = init;
	return (v: T | ((prev: T) => T)): void => {
		value = v as T;
		seen.push(`${value}`);
	};
}

interface Cell {
	setter: Setter<number> | null;
}

function store<T>(item: T): void {
	const cell: Cell = { setter: null };
	cell.setter = makeSetter(1 as number);
	if (cell.setter !== null) { cell.setter(2); }
}

function orZero(x: number | null): number { return x == null ? 0 : x; }

const early = makeSetter<float64>(40);
early(10);
store<float64>(1.0);

const wide: float64 | int32 = 2.5;
const narrow: number | int32 = wide;
seen.push(`${narrow}`);

const numFirst: number | ((p: number) => number) = 3.5;
const asFloat64: float64 | ((p: float64) => float64) = numFirst;
seen.push(`${asFloat64}`);

const some: float64 | null = 2.5;
const none: float64 | null = null;
seen.push(`${orZero(some)}`);
seen.push(`${orZero(none)}`);

const pair: [float64, string] = [1.5, "x"];
const same: [number, string] = pair;
seen.push(`${same[0]}`);

console.log(seen.join("|"));
