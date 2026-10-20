// @stdout: pattern 7 no no 8 no 9 no no no
// note: a conditional type with `infer` takes its true branch only when the check type is assignable to the extends type with the inferred types put in, as in TypeScript; binding an `infer` alone is not a match. A generic-interface pattern (`Pair<infer A, string>`), a struct pattern (`{ a: infer A; b: string }`) and a tuple pattern (`[infer A, string]`) each match once and take the false branch when a fixed part differs, when the tuple is shorter or longer, or when nothing binds. Each binding is typed by the branch it names, so a wrong branch is a compile error. Before, any binding took the true branch (`Pair<int32, int32>` gave `int32`). Same output on C, JS and the Raiser.
interface Pair<A, B> { a: A; b: B; }
interface Holder<T> { f: T; }
type FirstOf<P> = P extends Pair<infer A, string> ? A : "no";
type FieldOf<P> = P extends { a: infer A; b: string } ? A : "no";
type HeadOf<H> = H extends Holder<[infer A, string]> ? A : "no";
type Fits = { a: int32; b: string };
type Misfits = { a: int32; b: int32 };

const g1: FirstOf<Pair<int32, string>> = 7;
const g2: FirstOf<Pair<int32, int32>> = "no";
const g3: FirstOf<Holder<int32>> = "no";
const s1: FieldOf<Fits> = 8;
const s2: FieldOf<Misfits> = "no";
const t1: HeadOf<Holder<[int32, string]>> = 9;
const t2: HeadOf<Holder<[int32, int32]>> = "no";
const t3: HeadOf<Holder<[int32]>> = "no";
const t4: HeadOf<Holder<[int32, string, int32]>> = "no";
console.log(`pattern ${g1} ${g2} ${g3} ${s1} ${s2} ${t1} ${t2} ${t3} ${t4}`);
