// @stdout: owned=true | owned=true | owned=false | owned=false 7 | destructure | null3
// @stdout: 14
// @exit: 0
// @xfail(raiser): the Raiser has no host bridge for msGenericArrayPush, the rest accumulator of `const [x, setX, ...rest]` (inbox 2026-10-17-raiser-has-no-host-bridge-for-msgenericarraypush)
// note: `getImpl` of a name bound by destructuring answers the declaration that bound it, so a macro reads the call that created the value and its options: an array pattern and its rest element at module level, an object pattern, a local of a function body, and a name read inside a body that `getImpl` returned. These used to answer null. A for-of binding has no declaration of its own and still answers null.

import { creator, bodyRead, implKind } from "./meta";

interface Opts { owned: boolean; }
interface Pair { get: int32; set: int32; }
function make(v: int32, o: Opts): int32[] { return [v, o.owned ? 1 : 0, 9]; }
function pair(v: int32, o: Opts): Pair { return { get: v, set: o.owned ? 1 : 0 }; }
function bump(n: int32): int32 { return n + 1; }

const [x, setX, ...rest] = make(5, { owned: true });
const { get, set } = pair(3, { owned: false });

function local(): string {
	const [p, q] = make(7, { owned: false });
	return creator(q) + " " + (p + q).toString();
}

function usesSetter(): int32 {
	const [v, setV] = make(2, { owned: true });
	return bump(setV) + v;
}

function loopVar(): string {
	let seen = "";
	for (const [k, w] of [[1, 2]]) seen = implKind(w) + (k + w).toString();
	return seen;
}

console.log([creator(setX), creator(rest), creator(set), local(), bodyRead(usesSetter, bump), loopVar()].join(" | "));
console.log(x + setX + rest.length + get + set + usesSetter());
