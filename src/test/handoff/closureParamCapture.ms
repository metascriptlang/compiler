// A captured parameter is COPIED into the closure env, never addressed.
// Nim lambdalifting.nim:216 newAsgnStmt — capture through a parameter is the one
// case that generates an assignment; illegalCapture only rejects views and result.
// Storing `&param` instead makes the env point into a frame the closure outlives.

import { fullPipeline } from "./helpers";
import { Node, NodeKind, ProgramData, InterfaceDeclData, TypeKind } from "../../ast/node";

function findEnvDecl(prog: Node): Node {
	const pd = prog.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		if (stmt.kind == NodeKind.InterfaceDecl) {
			const id = stmt.data as InterfaceDeclData;
			if (id.interfaceName.length > 0 && id.interfaceName.charAt(0) == "$") {
				return stmt;
			}
		}
		i = i + 1;
	}
	return null as unknown as Node;
}

function envFieldKind(envDecl: Node, fieldName: string): TypeKind {
	const t = envDecl.nodeType;
	if (t == null) return TypeKind.Pending;
	let i = 0;
	while (i < t.typeNames.length) {
		if (t.typeNames[i] == fieldName) {
			if (i < t.typeChildren.length && t.typeChildren[i] != null) {
				return t.typeChildren[i].kind;
			}
		}
		i = i + 1;
	}
	return TypeKind.Pending;
}

test "a union param captured by an escaping closure is not stored as a pointer to the frame" {
	const src = "interface S { padding: number; }\nfunction make(s: S | null): () => boolean {\nreturn (): boolean => s === null;\n}";
	const prog = fullPipeline(src);
	assert prog != null;
	const env = findEnvDecl(prog);
	assert env != null;
	assert envFieldKind(env, "s") != TypeKind.Ptr;
}

test "an array param captured by an escaping closure is not stored as a pointer to the frame" {
	const src = "function make(xs: number[]): () => number {\nreturn (): number => xs.length;\n}";
	const prog = fullPipeline(src);
	assert prog != null;
	const env = findEnvDecl(prog);
	assert env != null;
	assert envFieldKind(env, "xs") != TypeKind.Ptr;
}
