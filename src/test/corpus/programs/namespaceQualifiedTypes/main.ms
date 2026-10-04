// @stdout: struct=3 class=5 generic=7 shared=9 local=40 enum=true
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table (a namespace-qualified `new`, as 807-namespaceImportClass)
// note: a type reached through a namespace import resolves through the module's exports: a struct parameter, a class annotation and `new`, a generic instance that is the same type the module's own functions take, an enum, and beside a local type of the same name.
import * as t from "./lib/types";
struct V { a: int32; b: int32; c: int32; }
function sum(v: t.V): int32 { return v.x + v.y; }
function run(): void {
	const v: t.V = { x: 1, y: 2 };
	const k: t.K = new t.K();
	const b: t.Box<int32> = new t.Box<int32>(7);
	const shared = new t.Box<int32>(9);
	const local: V = { a: 10, b: 10, c: 20 };
	const color: t.Color = t.Color.Green;
	console.log(`struct=${sum(v)} class=${k.n} generic=${b.value} shared=${t.unbox(shared)} local=${local.a + local.b + local.c} enum=${color == t.Color.Green}`);
}
run();
