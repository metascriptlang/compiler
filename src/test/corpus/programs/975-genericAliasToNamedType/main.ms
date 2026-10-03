// @stdout: alias 7 hi 3 7
// note: an instance of a generic alias whose body names another type IS that type (src/test/handoff/genericBinding.ms).
// `const a: Alias<string> = mkPlain()` was refused ("Type 'Plain' is not assignable to type 'Alias'"),
// parameter and return slots were refused on main, and C emitted a struct per alias instance, so the
// value-struct alias did not compile.

import { Plain, Holder, Alias, Box, P, mkPlain, mkPt } from "./genericAliasLib";

type Local<T> = Box<T>;

function viaAlias(x: Alias<boolean>): int32 { return x.n; }
function viaBox(b: Local<string>): string { return b.v; }
function backPt(p: P<string>): P<int32> { return p; }

function main(): void {
	const a: Alias<string> = mkPlain();
	const plain: Plain = a;
	const b: Box<string> = new Holder<string>("hi");
	const p = backPt(mkPt());
	console.log(`alias ${viaAlias(a)} ${viaBox(b)} ${p.x + p.y} ${plain.n}`);
}

main();
