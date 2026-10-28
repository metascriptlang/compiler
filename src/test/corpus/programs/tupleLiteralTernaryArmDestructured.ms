// @stdout: 3 4|3 4|5 6|1 2 3|0 0
// note: an array-literal arm of a ternary beside a tuple-typed arm takes the tuple type, so the destructured result is typed and holds its values on every backend, with the literal in either arm, inside a method, under a tuple alias and at three elements.

type Triple = [int32, int32, int32];
function pair(n: int32): [int32, int32] { return [n, n + 1]; }
function triple(n: int32): Triple { return [n, n + 1, n + 2]; }

class K {
	run(): string {
		const here: int32 | null = 5;
		const [from, to] = here === null ? [0, 0] : pair(here as int32);
		return `${from} ${to}`;
	}
}

function main(): void {
	const here: int32 | null = 3;
	const [from, to] = here === null ? [0, 0] : pair(here as int32);
	const [a, b] = here !== null ? pair(here as int32) : [0, 0];
	const [x, y, z] = here !== null ? triple(1) : [0, 0, 0];
	const none: int32 | null = null;
	const [p, q] = none === null ? [0, 0] : pair(none as int32);
	console.log(`${from} ${to}|${a} ${b}|${new K().run()}|${x} ${y} ${z}|${p} ${q}`);
}
main();
