// @skip-js: a sync function awaits here, which the JS backend refuses (checker/syncAwait.ms)
// @stdout: 3 2.5 true 7 x
// note: an await of Promise.resolve over a scalar reads the scalar itself, which holds no count to release: an int, a float and a boolean at the top level, an int in a sync function, and a string beside them that does hold one.

function inner(n: int32): int32 {
	return await Promise.resolve(n + 1);
}

const i = await Promise.resolve(3);
const f = await Promise.resolve(2.5);
const b = await Promise.resolve(true);
const s = await Promise.resolve("x");
console.log(`${i} ${f} ${b} ${inner(6)} ${s}`);
