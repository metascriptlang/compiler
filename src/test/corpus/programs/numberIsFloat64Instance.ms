// @stdout: 2.5|1.25|2|4.5|0.5|true
// @exit: 0

class E { code: int32 = 0 }

function intoFloat64(): Result<float64, E> { const x: number = 2.5; return Result.ok(x); }
function intoNumber(): Result<number, E> { const x: float64 = 1.25; return Result.ok(x); }
function intoArray(): Result<float64[], E> { const xs: number[] = [1.5, 2]; return Result.ok(xs); }
async function intoPromise(): Promise<Result<float64, E>> { const x: number = 4.5; return Result.ok(x); }

function ready(n: int32): Result<boolean, E> { return Result.ok(n > 0); }
function afterTry(n: int32): Result<float64, E> {
	const x: number = 0.5;
	const r = try ready(n);
	if (!r) return Result.ok(x);
	return Result.ok(1.0);
}

function elapsed(): Result<float64, E> {
	const start = performance.now();
	return Result.ok(performance.now() - start);
}

const a = intoFloat64();
const b = intoNumber();
const c = intoArray();
const d = await intoPromise();
const e = afterTry(0);
const t = elapsed();
console.log(`${a.ok ? a.value : -1}|${b.ok ? b.value : -1}|${c.ok ? c.value.length : -1}|${d.ok ? d.value : -1}|${e.ok ? e.value : -1}|${t.ok && t.value >= 0}`);
