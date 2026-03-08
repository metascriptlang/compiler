// Route 16: Union type as function parameter — codegen must emit struct, not void
//
// Bug: `createDoc(kind: DocKind, data: DocData)` where DocData is a union type
// emits `void data` in C instead of the actual DocData struct.

import { checkSource } from "./helpers";
import { compileToC, contains } from "../helpers";
import { TypeKind } from "../../checker/types";

test "union type alias resolves to TypeKind.Union in checker" {
	const ctx = checkSource(`
		type MyData =
			| { text: string }
			| { count: number };

		export function makeItem(kind: number, data: MyData): number {
			return kind;
		}
	`);
	let found = false;
	for (const sym of ctx.table.current.symbols) {
		if (sym.name === "makeItem") {
			const ft = sym.symbolType;
			assert ft.typeChildren.length === 2;
			assert ft.typeChildren[1].kind === TypeKind.Union;
			assert ft.typeChildren[1].typeName === "MyData";
			found = true;
		}
	}
	assert found;
}

test "union type param emits struct, not void" {
	const r = compileToC(`
		type MyData =
			| { text: string }
			| { count: number };

		export function makeItem(kind: number, data: MyData): number {
			return kind;
		}
	`);
	if (!r.ok) {
		console.log("COMPILE ERROR: " + r.error);
		assert false;
	}
	const cCode = r.value;
	console.log("=== C OUTPUT ===");
	console.log(cCode);
	console.log("=== END ===");
	// The union param should NOT be emitted as 'void'
	assert !contains(cCode, "void data");
	// It should contain the MyData type name
	assert contains(cCode, "MyData");
}

test "union type param in class factory" {
	const r = compileToC(`
		enum DocKind { Nil, Text }

		type DocData =
			| { text: string }
			| { children: number };

		class Doc {
			kind: DocKind;
			data: DocData;
		}

		export function createDoc(kind: DocKind, data: DocData): Doc {
			const d = new Doc();
			d.kind = kind;
			d.data = data;
			return d;
		}
	`);
	if (!r.ok) {
		console.log("COMPILE ERROR (class factory): " + r.error);
		assert false;
	}
	const cCode = r.value;
	assert !contains(cCode, "void data");
	assert contains(cCode, "DocData");
}
