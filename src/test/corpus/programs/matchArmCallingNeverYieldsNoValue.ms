// @stdout: -0.009999999776482582 -1.3300000429153442
// @stdout: assigned 2 returned 3 caught mode 9
// note: a match-expression arm that calls a never function was left as a bare call where a statement belongs: JS emitted `fail(...) break;` and C stopped with "processStmt has no arm for CallExpr"
function fail(message: string): never {
	throw new Error(message);
}

function scale(mode: int32): float32 {
	const s: float32 = match (mode) {
		0 => -0.01,
		1 => -1.33,
		_ => fail(`mode ${mode}`),
	};
	return s;
}

function pick(mode: int32): int64 {
	let n: int64 = 0;
	n = match (mode) {
		2 => 2,
		_ => fail(`mode ${mode}`),
	};
	return n;
}

function direct(mode: int32): int64 {
	return match (mode) {
		3 => 3,
		_ => fail(`mode ${mode}`),
	};
}

console.log(`${scale(0)} ${scale(1)}`);
let caught = "";
try { scale(9); } catch (e) { caught = (e as Error).message; }
console.log(`assigned ${pick(2)} returned ${direct(3)} caught ${caught}`);
