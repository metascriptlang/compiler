// @stdout: 7|7|7|7|7|7|7|7
// @exit: 0
// note: a call to a function declared `never` ends the flow like `throw`, so the guard `if (!r.ok) { stop(); }` narrows what follows, as the same guard with `throw` does. The matrix varies the callee (function, method, arrow) and the place of the read (flat, `while`, one loop, two nested loops, inside an arrow body); two loops deep used to lose the narrowing for `throw` as well.

function find(n: int32): Result<int32[], string> {
	if (n < 0) { return Result.err("neg"); }
	return Result.ok([n, n + 1]);
}

function stop(why: string): never { throw new Error(why); }

class Guard {
	fail(why: string): never { throw new Error(why); }
}

const guard = new Guard();
const stopArrow = (why: string): never => { throw new Error(why); };

function flat(): int32 {
	const found = find(3);
	if (!found.ok) { stop("no"); }
	return found.value[0] + found.value[1];
}

function viaMethod(): int32 {
	const found = find(3);
	if (!found.ok) { guard.fail("no"); }
	return found.value[0] + found.value[1];
}

function viaArrow(): int32 {
	const found = find(3);
	if (!found.ok) { stopArrow("no"); }
	return found.value[0] + found.value[1];
}

function inWhile(): int32 {
	const found = find(3);
	if (!found.ok) { stop("no"); }
	let sum = 0;
	let i = 0;
	while (i < 2) { sum += found.value[i]; i += 1; }
	return sum;
}

function twoLoops(): int32 {
	const found = find(3);
	if (!found.ok) { stop("no"); }
	let sum = 0;
	for (let w = 0; w < 1; w += 1) {
		for (let i = 1; i >= 0; i -= 1) { sum += found.value[i]; }
	}
	return sum;
}

function twoLoopsThrow(): int32 {
	const found = find(3);
	if (!found.ok) { throw new Error("no"); }
	let sum = 0;
	for (let w = 0; w < 1; w += 1) {
		for (let i = 1; i >= 0; i -= 1) { sum += found.value[i]; }
	}
	return sum;
}

function neverCallInLoop(): int32 {
	let sum = 0;
	for (let w = 0; w < 1; w += 1) {
		const found = find(3);
		if (!found.ok) { stop("no"); }
		sum += found.value[0] + found.value[1];
	}
	return sum;
}

function inArrowBody(): int32 {
	const read = (n: int32): int32 => {
		const found = find(n);
		if (!found.ok) { stop("no"); }
		return found.value[0] + found.value[1];
	};
	return read(3);
}

console.log([flat(), viaMethod(), viaArrow(), inWhile(), twoLoops(), twoLoopsThrow(), neverCallInLoop(), inArrowBody()].join("|"));
