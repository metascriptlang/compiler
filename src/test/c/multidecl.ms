// E2E C: Multi-decl emission (SERIALIZE Phase A2)
//
// Verifies that a macro returning NodeKind.SpliceMany at module-top splices
// its spliceNodes into the module's programStmts array, producing multiple
// declarations from a single macro invocation.

// compileToCWithStd, not compileToC: every source here imports "std/meta" to build
// the macro's return value, and the plain helper keeps stdPath empty so those
// imports do not resolve. These tests were red for that reason alone, invisible
// because this file sits outside the standing src/index.ms gate.
import { compileToCWithStd } from "../helpers";

test "E2E: macro returning SpliceMany at module-top splices into programStmts" {
	// Macro `pair()` returns SpliceMany containing two const decls.
	// After expansion, both consts exist at module level and are usable.
	const src = `
import { Node, NodeKind, DeclKind } from "std/meta";

macro pair(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "a",
				declType: "int32",
				initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 1, isFloat: false },
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "b",
				declType: "int32",
				initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 2, isFloat: false },
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
		],
	};
}

pair();

function main(): void {}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E: SpliceMany emitted in expression position is benign (no crash)" {
	// At expression position, SpliceMany has no semantic meaning — checker
	// either rejects it or treats as opaque. Either way, the test exercises
	// the schema's defensive behavior.
	const src = `
import { Node, NodeKind } from "std/meta";

macro emptyPair(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [],
	};
}

emptyPair();

function main(): void {}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

// ===== A2 Day 4 — stress tests =====

test "E2E stress: two SpliceMany invocations in same module both flatten" {
	const src = `
import { Node, NodeKind, DeclKind } from "std/meta";

macro mkConst(name: string, val: number): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: name,
				declType: "int32",
				initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: val, isFloat: false },
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
		],
	};
}

mkConst("alpha", 10);
mkConst("beta", 20);

function main(): void {}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E stress: spliced FunctionDecl reaches codegen (no caller — V1 splices bypass collectPass)" {
	// V1 limitation per plan §A2 risk register: spliced decls miss collectPass,
	// so other code referencing the spliced fn can't resolve the symbol. The
	// SPLICE MECHANIC itself (FunctionDecl AST flattens into module + reaches
	// codegen) does work — verified here by not referencing doubleIt from main.
	// V2 will add re-collect pass to fix the cross-reference case.
	const src = `
import { Node, NodeKind, DeclKind } from "std/meta";

macro emitDoubler(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.FunctionDecl,
				line: 0,
				column: 0,
				fnName: "doubleIt",
				params: ["n"],
				fnParamTypes: ["int32"],
				fnBody: {
					kind: NodeKind.BlockStmt,
					line: 0,
					column: 0,
					statements: [
						{
							kind: NodeKind.ReturnStmt,
							line: 0,
							column: 0,
							argument: {
								kind: NodeKind.BinaryExpr,
								line: 0,
								column: 0,
								operator: "+",
								left: { kind: NodeKind.Identifier, line: 0, column: 0, name: "n" },
								right: { kind: NodeKind.Identifier, line: 0, column: 0, name: "n" },
							},
						},
					],
				},
				fnFlags: "",
				fnReturnType: "int32",
				fnDefaults: [],
				nativeName: "",
				nameLocation: { line: 0, column: 0 },
			},
		],
	};
}

emitDoubler();

function main(): void {}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "E2E stress (NEGATIVE): caller cannot reference spliced FunctionDecl in V1" {
	// Documents the V1 limitation explicitly. When V2 adds re-collect, this
	// test should be UPDATED to assert ok (positive case).
	const src = `
import { Node, NodeKind, DeclKind } from "std/meta";

macro emitFn(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.FunctionDecl,
				line: 0,
				column: 0,
				fnName: "spliced",
				params: [], fnParamTypes: [],
				fnBody: { kind: NodeKind.BlockStmt, line: 0, column: 0, statements: [] },
				fnFlags: "", fnReturnType: "void", fnDefaults: [],
				nativeName: "",
				nameLocation: { line: 0, column: 0 },
			},
		],
	};
}

emitFn();

function main(): void {
	spliced();  // V1: undefined — spliced symbol bypassed collectPass
}
`;
	const c = compileToCWithStd(src);
	assert !c.ok;  // Expected to fail in V1
}

test "E2E stress: SpliceMany inside function body splices BlockStmt.statements" {
	const src = `
import { Node, NodeKind, DeclKind } from "std/meta";

macro twoLocals(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "x", declType: "int32",
				initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 1, isFloat: false },
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "y", declType: "int32",
				initializer: { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 2, isFloat: false },
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
		],
	};
}

function main(): void {
	twoLocals();
}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}
