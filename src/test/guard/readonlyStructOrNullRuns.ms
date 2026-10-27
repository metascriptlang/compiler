// A Readonly struct view converts into its own nullable and a mutable nullable widens to it
//
// INVARIANT (ULTRALOCK views): `Readonly<S> | null` is a nullable of the view, not of S, so a view
//   fits it, a `S | null` fits it, and it never fits `S | null` (readonlyStructOrNullRejects.ms).
//
// RED MEANS: the Maybe wrapper of a view and of its mutable struct are one type again, or the drop
//   check looks only at the wrapper's flag.
//
// GUARD-JS

struct TableInfo { id: int32; name: string; columns: Vec<string>; }
struct ModuleInfo { name: string; tables: Vec<TableInfo>; }

function tableNamed(module: Readonly<ModuleInfo>, name: string): Readonly<TableInfo> | null {
	for (const table of module.tables) {
		if (table.name == name) { return table; }
	}
	return null;
}

function idOf(t: Readonly<TableInfo> | null): int32 { return t === null ? -1 : t.id; }

function main(): void {
	const m: ModuleInfo = { name: "m", tables: [{ id: 7, name: "a", columns: [] }] };
	const widened: TableInfo | null = m.tables[0];
	const none: TableInfo | null = null;
	const found = idOf(tableNamed(m, "a"));
	const missing = idOf(tableNamed(m, "b"));
	if (found != 7 || missing != -1 || idOf(widened) != 7 || idOf(none) != -1) throw new Error(`${found} ${missing}`);
	console.log("GUARD-OK");
}

main();
