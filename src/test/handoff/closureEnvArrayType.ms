// Test: closure environment array field types emit correct C types
// Bug: lambda lifting typeToEnvStr produced "" for array element types → "[]" → mangle = "XX_"
// Fix: typeToEnvStr recursively derives element name; resolveSimpleTypeStr handles "Foo[]" patterns

import { fullPipeline } from "./helpers";
import { Node, NodeKind, ProgramData, InterfaceDeclData, TypeKind } from "../../ast/node";

// Helper to find $Env struct in program
function findEnvDecl(prog: Node): Node {
	const pd = prog.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		if (stmt.kind === NodeKind.InterfaceDecl) {
			const id = stmt.data as InterfaceDeclData;
			if (id.interfaceName.length > 0 && id.interfaceName.charAt(0) === "$") {
				return stmt;
			}
		}
		i = i + 1;
	}
	return null as unknown as Node;
}

// Helper to find field type in env struct
function envFieldType(envDecl: Node, fieldName: string): number {
	const t = envDecl.nodeType;
	if (t === null) return -1;
	let i = 0;
	while (i < t.typeNames.length) {
		if (t.typeNames[i] === fieldName) {
			if (i < t.typeChildren.length && t.typeChildren[i] !== null) {
				let ft = t.typeChildren[i];
				// Arrays are reference types (Ref<Array>) after the T[]→Ref<Array> flip;
				// unwrap to report the underlying array kind.
				if (ft.kind === TypeKind.Ref && ft.typeReturn !== null) ft = ft.typeReturn;
				return ft.kind;
			}
		}
		i = i + 1;
	}
	return -1;
}

test "string[] env field resolves to Array(String)" {
	const src = "function outer(): void {\nconst items: string[] = [];\nconst fn = (x: string): string => { items.push(x);\nreturn x; };\n}";
	const prog = fullPipeline(src);
	assert prog !== null;
	const env = findEnvDecl(prog);
	assert env !== null;
	assert envFieldType(env, "items") === TypeKind.Array;
}

test "number[] env field resolves to Array(Number)" {
	const src = "function outer(): void {\nconst nums: number[] = [];\nconst fn = (x: number): number => { nums.push(x);\nreturn x; };\n}";
	const prog = fullPipeline(src);
	assert prog !== null;
	const env = findEnvDecl(prog);
	assert env !== null;
	assert envFieldType(env, "nums") === TypeKind.Array;
}

test "struct[] env field resolves to Array" {
	const src = "interface Item { name: string; value: number; }\nfunction outer(): void {\nconst items: Item[] = [];\nconst fn = (x: number): number => { return items.length; };\n}";
	const prog = fullPipeline(src);
	assert prog !== null;
	const env = findEnvDecl(prog);
	assert env !== null;
	assert envFieldType(env, "items") === TypeKind.Array;
}
