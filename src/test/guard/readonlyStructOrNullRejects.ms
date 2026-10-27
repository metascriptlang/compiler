// A nullable view never converts back to a mutable nullable
//
// INVARIANT (ULTRALOCK views): `Readonly<S> | null` into `S | null` drops the view, as `Readonly<S>`
//   into `S` does, whether it is returned, bound or passed.
//
// RED MEANS: a nullable of a view fits a nullable of the mutable struct.
//
// GUARD-CHECK-FAIL a read-only view never converts back to the mutable type
// GUARD-CHECK-FAIL Argument type mismatch in 'takes'

struct TableInfo { id: int32; name: string; columns: Vec<string>; }
struct ModuleInfo { name: string; tables: Vec<TableInfo>; }

function find(module: Readonly<ModuleInfo>): Readonly<TableInfo> | null {
	for (const t of module.tables) { return t; }
	return null;
}
function toMutable(module: Readonly<ModuleInfo>): TableInfo | null {
	return find(module); // GUARD-REFUSED
}
function takes(t: TableInfo | null): void {}
function pass(module: Readonly<ModuleInfo>): void {
	takes(find(module)); // GUARD-REFUSED
}
