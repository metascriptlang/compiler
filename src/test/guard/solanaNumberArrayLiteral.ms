// GUARD-OS solana
// A number[] or float64[] literal builds its array element by element, as every other
// scalar literal does; SBF has no C varargs, so a variadic constructor does not link.
// RED MEANS a number literal went back to a variadic runtime call (NIM-REF TR-30).
import { instructionData, logU64 } from "std/solana";
function main(): void {
	const seed = instructionData().length as number;
	const values: number[] = [1.5, seed, -2];
	const wide: float64[] = [seed * 2, 0.25];
	logU64((values.length + wide.length) as uint64);
	logU64((values[1] + wide[0]) as uint64);
}
main();
