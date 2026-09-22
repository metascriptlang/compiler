// bug203 — a type parameter dropped the Readonly view it was bound to
//
// Symptom:    `id(ro)` and `pushG(xs, ro)` were refused for `ro: Readonly<N>`, while `first(ros).k = 5`
//             wrote through a `Readonly<N>[]` and `return first(ros)` turned the view back into `N`.
// Root cause: unification bound `T` to the mutable type behind the view, and the generic instance key
//             could not tell `N` from `Readonly<N>`, so the first instantiation decided both.
// Fix:        `T` binds the view itself, and a view in a type argument gives its own instance name.

import { compileToC } from "../helpers";

const header = `
interface N { k: int32; }
function id<T>(x: T): T { return x; }
function pushG<T>(arr: T[], v: T): void { arr.push(v); }
function first<T>(arr: T[]): T { return arr[0]; }
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug203: a view passes through a generic identity" {
	assert errorOf("function u(ro: Readonly<N>): int32 { const r = id(ro); return r.k; }") == "";
}

test "bug203: a view pushes into an array of views through a generic" {
	assert errorOf("function u(ro: Readonly<N>): int32 { const xs: Readonly<N>[] = []; pushG(xs, ro); return xs.length; }") == "";
}

test "bug203: a generic result read from an array of views stays read-only" {
	assert errorOf("function u(ros: Readonly<N>[]): void { first(ros).k = 5; }").indexOf("cannot write through") >= 0;
}

test "bug203: a generic result read from an array of views does not convert back" {
	assert errorOf("function u(ros: Readonly<N>[]): N { return first(ros); }").indexOf("never converts back") >= 0;
}

test "bug203: a mutable instance after a view instance stays writable" {
	assert errorOf("function u(ro: Readonly<N>): int32 { return id(ro).k; }\nfunction p(n: N): int32 { const r = id(n); r.k = 5; return r.k; }") == "";
}
