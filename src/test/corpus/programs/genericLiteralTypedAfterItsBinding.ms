// @stdout: twice 3 3 a!! 5|apply 42|memo 8 7 s|fold 7 7|annotated 7 7|seed s0
function twice<T>(f: (v: T) => T, x: T): T { return f(f(x)); }
function apply<A, B>(f: (a: A) => B, a: A): B { return f(a); }
function memo<T>(compute: (prev: T | null) => T): T { return compute(null); }
function fold<T>(compute: (a: T | null, b: T | null) => T): T { return compute(null, null); }
function seed<T>(f: (n: int32, prev: T | null) => T): T { return f(0, null); }

const out: string[] = [];

const a = twice(n => n + 1, 1);
const s = twice(t => t + "!", "a");
const deep = twice(n => twice(m => m + 1, n), 1);
out.push(`twice ${a} ${twice(n => n + 1, 1).toString()} ${s} ${deep}`);

const b = apply(x => x * 2, 21);
out.push(`apply ${b}`);

const m1 = memo(() => 8);
const m2 = memo((): int32 => 7);
const m3 = memo(() => "s");
out.push(`memo ${m1} ${m2} ${m3}`);

const f1 = fold((x: int32 | null): int32 => 7);
const f2 = fold((): int32 => 7);
out.push(`fold ${f1} ${f2}`);

const p1 = fold((x: int32 | null, y) => 7);
const p2 = memo((p): int32 => 7);
out.push(`annotated ${p1} ${p2}`);

const s1 = seed((n) => "s" + n);
out.push(`seed ${s1}`);

console.log(out.join("|"));
