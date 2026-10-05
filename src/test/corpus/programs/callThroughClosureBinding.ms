// @stdout: 11 12 36 41 6 13
// note: a call through a local or a parameter calls the closure that binding holds, even when a routine elsewhere in the program (std has an `add`) shares its name: a capture of a parameter, a const, a let changed after the capture, a loop body, a callback parameter and a non-capturing local. Before, the Raiser called the routine by its spelling.
function viaParam(add: (x: int32) => int32): int32 {
	return add(1);
}

function main(): void {
	const k: int32 = 10;
	const add = (x: int32): int32 => x + k;
	let j: int32 = 10;
	const bump = (x: int32): int32 => x + j;
	j = j + 1;
	let total: int32 = 0;
	for (const x of [1, 2, 3]) {
		const add = (v: int32): int32 => v + k;
		total += add(x);
	}
	const has = (x: int32): int32 => x * 3;
	const pick = (x: int32): int32 => add(x) + 2;
	console.log(`${add(1)} ${bump(1)} ${total} ${viaParam((x: int32): int32 => x + 40)} ${has(2)} ${pick(1)}`);
}
main();
