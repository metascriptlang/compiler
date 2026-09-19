// `unknown` is pointer-top and deliberately outside reference counting, so a
// field typed `unknown | null` must not be either: the store side never increfs
// it, and a destroy hook that decrefs it frees a value nobody owned.

import { fullPipeline } from "./helpers";
import { Node, NodeKind, ProgramData, FunctionDeclData } from "../../ast/node";

function destroyHookNames(prog: Node, prefix: string): string[] {
	const out: string[] = [];
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl) {
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnName.startsWith(prefix) && fd.fnName.endsWith("Destroy")) { out.push(fd.fnName); }
		}
	}
	return out;
}

const NULLABLE = "interface Box { a: unknown | null; }\nfunction main(): void {\nconst b: Box = { a: null };\nconsole.log(b.a === null ? \"n\" : \"v\");\n}\nmain();";
const PLAIN = "interface Box { a: unknown; }\nfunction main(): void {\nconst b: Box = { a: null };\nconsole.log(b.a === null ? \"n\" : \"v\");\n}\nmain();";

test "an unknown|null field gets the same destroy hooks as a plain unknown field" {
	const nullable = fullPipeline(NULLABLE);
	const plain = fullPipeline(PLAIN);
	assert nullable != null;
	assert plain != null;
	const a = destroyHookNames(nullable, "Box");
	const b = destroyHookNames(plain, "Box");
	assert a.length == b.length, "nullable=" + a.length.toString() + " plain=" + b.length.toString();
}
