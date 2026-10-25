// @stdout: imported a! true false
// An imported function with fewer parameters fills a wider slot, and stays identical to itself.
import { shout, quiet } from "./lib";

function apply(f: (s: string, i: int32) => string): string { return f("a", 1); }

function main(): void {
	const wide: (n: int32) => void = quiet;
	const again: (n: int32) => void = quiet;
	const other = (): void => {};
	const third: (n: int32) => void = other;
	wide(1);
	console.log(`imported ${apply(shout)} ${wide === again} ${wide === third}`);
}

main();
