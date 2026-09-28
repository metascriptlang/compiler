// Parity program — a generic call whose return is a bare type parameter
// binds it from its arguments only; the type its result is cast or
// assigned to never retypes a literal argument.
//
// @stdout: 7|1|7|7|7|700
// @exit: 0

function pick<T>(a: T, b: T): T { return a; }

const out: string[] = [];

const power: int32 = 7;
const viaMax = Math.max(power, 1) as int64;
const viaMin = Math.min(power, 1) as uint64;
const viaPick = pick(power, 1) as int64;
const literalFirst = Math.max(1, power) as int64;
const declared: int64 = pick(power, 1);
const inExpr = (power as int64) * 100 / (Math.max(power, 1) as int64) * 7;
out.push(`${viaMax}`);
out.push(`${viaMin}`);
out.push(`${viaPick}`);
out.push(`${literalFirst}`);
out.push(`${declared}`);
out.push(`${inExpr}`);
console.log(out.join("|"));
