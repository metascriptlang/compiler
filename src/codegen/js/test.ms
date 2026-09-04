// JavaScript Codegen — Test Infrastructure
//
// Mirrors codegen/c/test.ms: TestDecl → wrapper function + registry entry.
// Only active when isTestBuild=true; production builds strip TestDecl.
// The wrapper is exported so the generated runner can reach it through a
// namespace import without knowing per-module naming.

import { Node, NodeKind, TestDeclData, BlockStmtData } from "../../ast/node";
import { JSGenerator, emit, emitIndent, emitNode, emitNewline } from "./emit";

export function emitTestDecl(gen: JSGenerator, node: Node): void {
	if (!gen.isTestBuild) return;
	const d = node.data as TestDeclData;
	if (d.testBody === null) return;

	const funcName = `__ms_test_${gen.testNames.length.toString()}`;
	gen.testNames.push(d.testName);
	gen.testFuncs.push(funcName);

	emitIndent(gen);
	emit(gen, `export async function ${funcName}() `);
	if (d.testBody.kind === NodeKind.BlockStmt) {
		emitNode(gen, d.testBody);
	} else {
		emit(gen, "{}\n");
	}
	emitNewline(gen);
}
