// @stdout: tuple 3 s x 4 pair
// note: `infer` inside a tuple pattern binds element by element, as in TypeScript: at position 0, at position 1 and in both positions, inside a generic argument. A generic call infers its type parameters from a tuple parameter the same way (`second<A, B>(p: [A, B])`). Each binding is typed by the branch it names, so a wrong branch is a compile error. Before, the tuple bound nothing: the conditional took its false branch and the call could not instantiate `A`. Mismatching tuples are pinned by conditionalTypeChecksTheInferredPattern. Same output on C, JS and the Raiser.
interface Holder<T> { f: T; }
type First<H> = H extends Holder<[infer A, string]> ? A : "no";
type Second<H> = H extends Holder<[int32, infer B]> ? B : "no";
type Swap<H> = H extends Holder<[infer A, infer B]> ? [B, A] : "no";

function second<A, B>(p: [A, B]): B { return p[1]; }

const a: First<Holder<[int32, string]>> = 3;
const b: Second<Holder<[int32, string]>> = "s";
const c: Swap<Holder<[int32, string]>> = ["x", 4];
const pair: [int32, string] = [1, "pair"];
console.log(`tuple ${a} ${b} ${c[0]} ${c[1]} ${second(pair)}`);
