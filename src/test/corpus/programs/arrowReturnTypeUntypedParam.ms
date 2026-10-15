// @xfail(raiser): raiser runtime error: cannot evaluate typeof at comptime: 'function' and 'number' variants share Raiser value kind 2 (inbox 2026-09-26-raiser-typeof-yields-the-value)
// Parity program — an arrow with one untyped parameter and a return type is an arrow,
// and the true arm of a conditional keeps the colon that ends it: a parenthesized
// true arm is not mistaken for the head of an arrow in the false arm.
//
// @stdout: v2|e2|f1|zero|5|a2|function|function|function|object|number|3
// @exit: 0

function call<T>(fn: (n: number) => T): T { return fn(2); }
function call2<T>(fn: (a: number, b: number) => T): T { return fn(2, 3); }
function zero<T>(fn: () => T): T { return fn(); }

const y = 2;
const c = true;
const off = false;
const out: string[] = [];

out.push(call((n): string => { return "v" + n; }));
out.push(call((n): string => "e" + n));
const f: (n: number) => string = (n): string => { return "f" + n; };
out.push(f(1));
out.push(zero((): string => "zero"));
out.push(call2((a, b): number => a + b).toString());

const pick = off ? (y) : (n: number): number => n + 1;
const colonEnds: ((v: number) => number) | null = c ? (v): number => v : null;
const objectArm: (v: number) => { y: number } = c ? y => ({ y }) : z => ({ y: z });
const parenObject = c ? ({ a: 1 }) : z => z;
const other = { a: 2 };
const noSemicolon = c ? ({ a: 1 }) : other
const next = (z: number): number => z + 1
const nested = c ? (y) : z => z;

async function later(): Promise<void> {
	const p = call(async (n): Promise<string> => "a" + n);
	out.push(await p);
	out.push(typeof pick);
	out.push(typeof colonEnds);
	out.push(typeof objectArm);
	out.push(typeof parenObject);
	out.push(typeof nested);
	out.push((noSemicolon.a + next(1)).toString());
	console.log(out.join("|"));
}
later();
