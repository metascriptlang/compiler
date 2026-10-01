// Parity program — a generic function overloaded with a non-generic one: the
// call that picks the generic instantiates it from its arguments, whatever
// the call's result flows into (a cast, a typed slot, a parameter, a log).
//
// @stdout: 7|7|7|1|7|5|8|5|s
// @exit: 0

function pick<T>(a: T, b: T): T { return a; }
function pick(a: string): string { return a; }
function apply<T>(x: T, f: (v: T) => T): T { return f(x); }
function apply(x: string): string { return x; }
function show(x: int32): int32 { return x; }

const out: string[] = [];

const power: int32 = 7;
const q: int32 = 3;
const viaCast = pick(power, 1) as int64;
const declared: int64 = pick(power, q);
out.push(`${viaCast}`);
out.push(`${declared}`);
out.push(`${show(pick(power, 1))}`);
out.push(`${pick(1, power)}`);
out.push(`${pick(power, power)}`);
const n: int32 = 4;
const r: int64 = apply(n, (v) => v + 1);
out.push(`${r}`);
out.push(`${apply(n, (v) => v * 2)}`);
out.push(`${apply<int64>(4, (v) => v + 1)}`);
out.push(pick("s"));
console.log(out.join("|"));
