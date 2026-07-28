// bug058 — a missing function-typed field was silently NULL, then segfaulted
//
// Nim parity (semobjconstr.nim collectMissingFields): a field left out of an
// object construction is default-initialized UNLESS its type requiresInit. A
// function field's zero is NULL and calling NULL is a segfault, so it has no
// valid default. Before this check, `return { f: … }` for an interface with an
// unmentioned `g` compiled clean and died at the call site (exit 139).
//
// Value/nullable fields keep Nim's default-init behaviour — only the
// no-valid-zero case is rejected.

import { compileToCWithStd } from "../helpers";

test "bug058: a missing function field is rejected" {
	const src = `
interface H { f: (n: number) => void; g: (n: number) => void; }
function mk(): H {
	return { f: (n: number): void => { console.log(n); } };
}
function main(): void { mk().g(1); }
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	assert c.error.indexOf("field 'g' must be initialized", 0) >= 0;
}

test "bug058: a nullable function field may be omitted" {
	const src = `
interface H { f: (n: number) => void; g: ((n: number) => void) | null; }
function mk(): H {
	return { f: (n: number): void => { console.log(n); } };
}
function main(): void { mk().f(1); }
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "bug058: value fields keep Nim default-init" {
	const src = `
interface P { a: number; b: string; c: number[]; }
function mk(): P { return { a: 1 }; }
function main(): void { console.log(mk().a); }
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}
