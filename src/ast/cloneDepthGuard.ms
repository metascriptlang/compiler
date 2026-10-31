// Guard: cloning a deeply nested expression stays inside the stack at -O0
//
// INVARIANT: the frame that recurses through `rebuildNodeData` holds only the
//   dispatch, never one kind's locals. A frame sized by every kind together was
//   ~335 KB at -O0, so a `return x+x+...` of 45 terms overflowed the 8 MB stack.
//
// RED MEANS: a kind's body was inlined back into `rebuildNodeData`; keep one
//   helper per kind. Only a build without `--danger` shows it (the default of `msc test`).

import { parseSourceLenient } from "../parser/statements/validation";
import "../parser/statements/core";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { Node, NodeKind, ProgramData, FunctionDeclData, BlockStmtData, ReturnStmtData, BinaryExprData } from "./node";

const TERMS = 400;

function chainSource(): string {
	let src = "function f(x: int32): int32 { return x";
	for (let i = 1; i < TERMS; i += 1) src = src + " + x";
	return src + "; }";
}

function spineLength(program: Node): int32 {
	const fn = (program.data as ProgramData).programStmts[0];
	const ret = ((fn.data as FunctionDeclData).fnBody.data as BlockStmtData).statements[0];
	let cur = (ret.data as ReturnStmtData).argument as Node;
	let count = 0;
	while (cur.kind == NodeKind.BinaryExpr) {
		count = count + 1;
		cur = (cur.data as BinaryExprData).left;
	}
	return count;
}

test "clone depth guard: a 400-term chain clones without overflowing the stack" {
	const pr = parseSourceLenient(chainSource());
	assert pr.ok, "the chain no longer parses, the guard would pass vacuously";
	const copy = cloneNodeForCheck(pr.value);
	assert spineLength(pr.value) == TERMS - 1;
	assert spineLength(copy) == TERMS - 1;
}
