import { checkProjectDiagnostics, compileToCWithStd } from "../helpers";

const TABLE = `
struct Table { name: string; keyOf: Sendable<(id: uint32) => uint32>; }
function make(base: uint32): Table {
	const salt = base * 3;
	return { name: "t" + String(base), keyOf: (id: uint32): uint32 => id + salt };
}
`;
const PLAIN = TABLE + "export const T = make(7);\n";
const READONLY = TABLE + "export const T: Readonly<Table> = make(7);\n";
const TASKS = `
const tasks: Promise<uint32>[] = [];
for (let i = 0; i < 4; i++) tasks.push(spawn(() => probe(3)));
let total: uint32 = 0;
for (const t of tasks) total = total + await t;
console.log(String(total));
`;

function routineC(c: string, name: string): string {
	let at = c.indexOf(" " + name + "__");
	while (at >= 0) {
		const eol = c.indexOf("\n", at);
		if (eol > 3 && c.substring(eol - 3, eol) == ") {") {
			const close = c.indexOf("\n}\n", eol);
			return close < 0 ? c.substring(eol) : c.substring(eol, close);
		}
		at = c.indexOf(" " + name + "__", at + 1);
	}
	return "";
}

function refuses(source: string, text: string): boolean {
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) return true;
	}
	return false;
}

test "moduleConstShare: a local bound from a module const that tasks share takes no count, as the checker let it cross" {
	const shapes = [
		{ name: "a local bound to its closure field", probe: "function probe(i: uint32): uint32 { const k = T.keyOf; return k(i); }" },
		{ name: "a local copy of the const", probe: "function probe(i: uint32): uint32 { const t = T; return t.keyOf(i); }" },
	];
	for (const arm of [{ name: "plain", decls: PLAIN }, { name: "Readonly", decls: READONLY }]) {
		for (const shape of shapes) {
			const label = arm.name + " const, " + shape.name;
			const result = compileToCWithStd(arm.decls + shape.probe + TASKS);
			assert result.ok, label + ": " + (result.ok ? "" : result.error);
			const body = routineC(result.value, "probe");
			assert body != "", label + ": probe not found in the emitted C";
			assert !body.contains("Copy(") && !body.contains("msIncref"), label + " counts the shared value:\n" + body;
		}
	}
}

const REFUSED = "stores the module const 'T' into the owned result it returns";

test "moduleConstShare: an owned result returning a shared module const's interior is refused in code a task runs" {
	const refused = [
		{ name: "a plain const's closure field", source: PLAIN + "function get(): Sendable<(id: uint32) => uint32> { return T.keyOf; }\nfunction probe(i: uint32): uint32 { return get()(i); }" + TASKS },
		{ name: "a Readonly const's closure field", source: READONLY + "function get(): Sendable<(id: uint32) => uint32> { return T.keyOf; }\nfunction probe(i: uint32): uint32 { return get()(i); }" + TASKS },
		{ name: "an arrow with an expression body", source: READONLY + "const get = (): Sendable<(id: uint32) => uint32> => T.keyOf;\nfunction probe(i: uint32): uint32 { return get()(i); }" + TASKS },
		{ name: "a return through a local", source: PLAIN + "function get(): Sendable<(id: uint32) => uint32> { const k = T.keyOf; return k; }\nfunction probe(i: uint32): uint32 { return get()(i); }" + TASKS },
	];
	for (const item of refused) assert refuses(item.source, REFUSED), item.name;
}

test "moduleConstShare: a call through the field, a view result and a return outside tasks compile" {
	const legal = [
		{ name: "a call through the closure field", source: PLAIN + "function probe(i: uint32): uint32 { return T.keyOf(i); }" + TASKS },
		{ name: "a Readonly result returns the const as a borrow", source: READONLY + "function view(): Readonly<Table> { return T; }\nfunction probe(i: uint32): uint32 { return view().keyOf(i); }" + TASKS },
		{ name: "an owned return no task reaches", source: PLAIN + "function get(): Sendable<(id: uint32) => uint32> { return T.keyOf; }\nconsole.log(String(get()(1)));" },
	];
	for (const item of legal) {
		const result = compileToCWithStd(item.source);
		assert result.ok, item.name + ": " + (result.ok ? "" : result.error);
	}
}
