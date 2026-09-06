// bug090 — two anonymous-struct type args collapsed onto ONE generic instance
//
// Symptom:    `wrap<A1>(...)` and `wrap<A2>(...)` in one binary, where A1 and A2
//             are aliases of DIFFERENT anonymous object types, reported
//             "Property 'tag' does not exist on type 'object'. Available: name"
//             — the second call was checked against the first one's body.
// Root cause: the instantiation cache key is `mangleMonoName` → `monoTypeKey`
//             (instantiate.ms looks the mangled name up in scope), and
//             `monoTypeKey`'s Struct arm returned `t.typeName` verbatim, which
//             is "" for an anonymous struct. Both instantiations keyed as
//             `wrap__`, so the second reused the first's symbol.
// Fix:        src/monomorphize/registry.ms — anonymous structs key on a
//             structural signature (field names + field type keys), and the
//             catch-all arm keys on the kind ordinal plus name/structure
//             instead of the shared constant "unknown".

type Named = { name: string };
type Tagged = { tag: string };

function wrapOne<T>(v: T): Result<T, string> { return Result.ok(v); }

test "bug090: distinct anon-struct type args get distinct instantiations" {
	const a = wrapOne<Named>({ name: "n1" });
	const b = wrapOne<Tagged>({ tag: "t2" });
	assert a.ok;
	assert b.ok;
	if (a.ok) assert a.value.name == "n1";
	if (b.ok) assert b.value.tag == "t2";
}

test "bug090: same anon-struct shape still shares one instantiation" {
	const a = wrapOne<Named>({ name: "x" });
	const b = wrapOne<Named>({ name: "y" });
	if (a.ok && b.ok) assert a.value.name != b.value.name;
}
