// Sibling helper for bug059.
//
// Declares a module-private generic whose name and type-arg match the one in
// bug059.ms. Two modules each owning a same-named generic is ordinary module
// scoping (neither is exported), and the C name mangler already keeps them
// apart by module path — so both instances must survive to codegen.
//
// This module is loaded FIRST (bug059.ms imports it), so its instance wins the
// pending-list race and bug059.ms's instance is the one that used to vanish.

function pendingDedup<T>(x: T | null): int32 {
	return 1;
}

test "bug059helper: same-named generic instantiates in the first module" {
	const w: int32 | null = null;
	assert pendingDedup(w) == 1;
}
