// bug553 — a generic instance stored in another module's generic lost its type arguments
//
// Symptom:    `new HashMap<string, Cell<int32> >()` then `m.set("a", …)` with `struct Cell<T>` was refused
//             ("in instantiation of 'set<string, Cell>': Type 'Vec<HashMapEntry>' is not assignable to type
//             'Vec<HashMapEntry>'"); with a class or interface value C declared the entry vector under two
//             names and the build failed.
//
// Root cause: the generic body is re-checked in the module that defines it, where `Cell` names the caller's
//             declaration through a type alias of that name. bug552 resolved `Alias<A>` to the alias body when
//             the body is a declared type, so `Cell<int32>` became the bare generic `Cell`.
//
// Fix:        an alias whose body is a generic declaration hands its arguments to that declaration; only an
//             alias of a complete declared type resolves to the body.

import { errorCount } from "../handoff/helpers";

const CELL = "struct Cell553<T> { v: T; }\n";

test "bug553: a generic struct instance fills a std HashMap value" {
	assert errorCount(CELL + "const m = new HashMap<string, Cell553<int32> >();\nm.set(\"a\", { v: 1 as int32 });\nconst n: number = m.size;\n") == 0;
}

test "bug553: a generic struct instance fills a std Map value" {
	assert errorCount(CELL + "const m = new Map<string, Cell553<string> >();\nm.set(\"a\", { v: \"x\" });\nconst n: number = m.size;\n") == 0;
}

test "bug553: an alias of a generic instance fills a std HashMap value" {
	assert errorCount(CELL + "type Boxed553<T> = Cell553<T>;\nconst m = new HashMap<string, Boxed553<int32> >();\nm.set(\"a\", { v: 2 as int32 });\n") == 0;
}
