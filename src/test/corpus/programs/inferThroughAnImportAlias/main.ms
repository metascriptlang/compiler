// @stdout: 7 7 7 7 7 7 7 hi
// note: an `infer` pattern names the declaration behind an import alias, so `CdBx_a<infer U>`
// matches an argument spelled `CdBx<int32>`; it used to reduce to never and refuse every call.
import { CdBx } from "./box";
import * as ns from "./unboxAliased";
import { CdUnbox, CdIsBx, cdG } from "./unboxAliased";
import * as plain from "./unboxPlain";
import { CdUnbox as PlainUnbox } from "./unboxPlain";

interface LocalBx<V> {
	v: V;
}
type LocalUnbox<T> = T extends LocalBx<infer U> ? U : never;

function viaNamespace(a: ns.CdUnbox<CdBx<int32>>): int32 { return a; }
function viaNamed(a: CdUnbox<CdBx<int32>>): int32 { return a; }
function plainNamespace(a: plain.CdUnbox<CdBx<int32>>): int32 { return a; }
function plainNamed(a: PlainUnbox<CdBx<int32>>): int32 { return a; }
function local(a: LocalUnbox<LocalBx<int32>>): int32 { return a; }
function noInfer(a: CdIsBx<CdBx<int32>>): int32 { return a; }
function text(a: CdUnbox<CdBx<string>>): string { return a; }

console.log(`${viaNamespace(7)} ${viaNamed(7)} ${plainNamespace(7)} ${plainNamed(7)} ${local(7)} ${noInfer(7)} ${cdG(7)} ${text("hi")}`);
