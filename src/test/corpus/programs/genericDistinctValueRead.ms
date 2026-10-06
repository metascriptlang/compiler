// @stdout: generic-distinct-value 14 21 3 true 4

type ValueRead<T> = distinct (() => T);
export function valueOf<T>(this source: ValueRead<T>): T { return source(); }

function observeReads(): void {
	let reads: int32 = 0;
	const integer = (() => { reads += 1; return 7 as int32; }) as ValueRead<int32>;
	const decimal = (() => 1.5 as float64) as ValueRead<float64>;
	const doubled: int32 = integer * 2;
	const tripled: int32 = 3 * integer;
	const fractional: float64 = decimal * 2;
	const equal: boolean = integer === 7;
	const negative: int32 = -integer;
	if (negative != -7 || reads != 4) process.exit(1);
	console.log("generic-distinct-value", doubled, tripled, fractional, equal, reads);
}

observeReads();
