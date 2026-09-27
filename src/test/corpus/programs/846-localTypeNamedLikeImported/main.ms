// note: inbox card 2026-09-24-local-interface-same-name-as-dependency-links-twice. A local interface named like an interface of an imported module emitted its TypeInfo under the imported module's mangled name (lld-link: duplicate symbol Options__<lib>TypeInfo): codegen named the lifter's TypeInfo var through the TU's bare-name cache. Fix 7a819b26: the lifter carries the hook base C name. The imported Options is used too, under an alias.

import { Handle, open, Options as TheirOptions } from "./localTypeNamedLikeImportedLib";

interface Options { name: string; }

function describe(o: Options, h: Handle): void { console.log(`${o.name} ${h.id}`); }

function run(): void {
	const t: TheirOptions = { title: "theirs" };
	describe({ name: "mine" }, open(t));
	describe({ name: "again" }, open({ title: "direct" }));
}
run();
