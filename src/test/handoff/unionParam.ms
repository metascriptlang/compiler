// Route 16: Union type as function parameter — codegen must emit struct, not void
//
// Bug: `createDoc(kind: DocKind, data: DocData)` where DocData is a union type
// emits `void data` in C instead of the actual DocData struct.

import { TypeKind } from "../../ast/node";
import { checkSource, errorCount, hasError } from "./helpers";
import { compileToC } from "../helpers";

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
	for (const sym of ctx.table.current.symbols.values()) {
		if (sym.name == "makeItem") {
			const ft = sym.symbolType;
			assert ft.typeChildren.length == 2;
			assert ft.typeChildren[1].kind == TypeKind.Union;
			assert ft.typeChildren[1].typeName == "MyData";
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
	if (!r.ok) console.log("COMPILE ERROR: " + r.error);
	assert r.ok;
	const cCode = r.value;
	console.log("=== C OUTPUT ===");
	console.log(cCode);
	console.log("=== END ===");
	// The union param should NOT be emitted as 'void'
	assert !cCode.contains("void data");
	// It should contain the MyData type name
	assert cCode.contains("MyData");
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
	if (!r.ok) console.log("COMPILE ERROR (class factory): " + r.error);
	assert r.ok;
	const cCode = r.value;
	assert !cCode.contains("void data");
	assert cCode.contains("DocData");
}

test "a union holding true and false takes a boolean" {
	assert errorCount("function k(b: boolean): true | false { return b; }\nfunction j(b: boolean): true | false | int32 { return b; }\n") == 0;
}

test "a string literal goes into a union with several string literals, and a string that may be none of them is refused" {
	assert errorCount("function g(x: int32): \"a\" | \"b\" | int32 { if (x > 0) return \"b\"; if (x < 0) return \"a\"; return x; }\n") == 0;
	assert errorCount("type K = \"a\" | \"b\";\nfunction g(k: K): K | int32 { return k; }\n") == 0;
	assert hasError("function g(s: string): \"a\" | \"b\" | int32 { return s; }\n",
		"Type 'string' is not assignable to type '\"a\" | \"b\" | int32'");
	assert hasError("function g(): \"a\" | \"b\" | int32 { return \"c\"; }\n", "is not assignable to type '\"a\" | \"b\" | int32'");
}
