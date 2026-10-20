// @stdout: arrow 5 7 9 5 10 11 fn other fn other none
// note: the `=>` of a function type inside a conditional type is one token, not a closing angle, as in TypeScript: a function type in the extends type (`Holder<() => infer R>`, `Holder<(x: infer A) => void>`, a nested arrow), in the true branch (bare and parenthesised), in the false branch and in a parenthesised check type leaves the conditional's `extends`, `?` and `:` where TypeScript reads them, and a check type that is not a function still takes the false branch. Each binding is typed by the branch it names, so a wrong branch is a compile error. Before, an arrow ahead of the `?` or the `:` hid it and the alias stayed unresolved (`Ret<Holder<function>>`). Same output on C, JS and the Raiser.
interface Holder<T> { f: T; }
type Ret<H> = H extends Holder<() => infer R> ? R : "none";
type Arg<H> = H extends Holder<(x: infer A) => void> ? A : "none";
type Deep<H> = H extends Holder<(f: (x: int32) => int32) => infer R> ? R : "none";
type Cb<T> = T extends string ? (x: int32) => int32 : "none";
type CbParen<T> = T extends string ? ((x: int32) => int32) : "none";
type Alt<T> = T extends string ? "none" : (x: int32) => int32;
type Fn0 = () => int32;
type IsFn0<T> = (() => T) extends Fn0 ? "fn" : "other";
type IsHolderFn<H> = H extends Holder<() => int32> ? "fn" : "other";

const r: Ret<Holder<() => int32>> = 5;
const a: Arg<Holder<(x: int32) => void>> = 7;
const d: Deep<Holder<(f: (x: int32) => int32) => int32>> = 9;
const cb: Cb<string> = (x: int32): int32 => x + 1;
const cp: CbParen<string> = (x: int32): int32 => x * 2;
const alt: Alt<int32> = (x: int32): int32 => x + 10;
const f0: IsFn0<int32> = "fn";
const f1: IsFn0<string> = "other";
const h0: IsHolderFn<Holder<() => int32>> = "fn";
const h1: IsHolderFn<Holder<int32>> = "other";
const miss: Ret<Holder<int32>> = "none";
console.log(`arrow ${r} ${a} ${d} ${cb(4)} ${cp(5)} ${alt(1)} ${f0} ${f1} ${h0} ${h1} ${miss}`);
