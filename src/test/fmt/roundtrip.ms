// Fmt roundtrip test harness.
//
// Goal: assert that `fmt(source)` preserves the AST structurally — i.e.
// re-parsing the formatted output yields the same kind-tree (and key
// scalars: operator strings, identifier names, literal values, member
// property names) as parsing the original.
//
// This is the contract every formatter MUST hold: formatting is a pure
// pretty-print. If the structure shifts, parens were dropped or operators
// were reordered, and the program now runs differently.

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core"; // side-effect: register sub-parsers
import { resetAllSideChannels, getGenericDecl } from "../../parser/context";
import { Node, NodeKind,
	IdentifierData, NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData,
	TypeAssertionData, ConditionalExprData, SpreadExprData, NewExprData,
	TryExprData, MatchExprData, MatchCaseData, AwaitExprData, YieldExprData,
	MoveExprData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	ForStmtData, ForOfStmtData, DoWhileStmtData, BlockStmtData, FunctionDeclData,
	VariableDeclData, ImportDeclData, ProgramData, ThrowStmtData, TryCatchStmtData,
} from "../../ast/node";
import { printNode } from "../../compiler/fmt/printer/index";
import { formatDoc } from "../../compiler/fmt/layout";
import { defaultFormatOptions } from "../../compiler/fmt/options";

// Run fmt over source text; returns formatted output (or "" on parse fail).
export function fmt(source: string): string {
	const parsed = parseSource(source);
	if (!parsed.ok) return "";
	const opts = defaultFormatOptions();
	opts.source = source;
	const doc = printNode(parsed.value, opts);
	return formatDoc(doc, opts);
}

// Structural fingerprint: kind-tree + key scalars, ignoring positions and
// comments. Two ASTs with identical fingerprints are semantically the same
// program.
export function astShape(node: Node): string {
	if (node === null) return "null";
	const k = NodeKind[node.kind];
	return match (node.kind) {
		// --- Literals (key scalar identifies the literal) ---
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			return k + "[" + d.value.toString() + "]";
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			return k + "[" + d.value + "]";
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			return k + "[" + (d.boolValue ? "true" : "false") + "]";
		},
		NodeKind.NullLiteral => k,
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			return k + "[" + d.name + "]";
		},

		// --- Expression nodes with operators / discriminators ---
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			return k + "[" + d.operator + "](" + astShape(d.left) + "," + astShape(d.right) + ")";
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			return k + "[" + d.unaryOp + "](" + astShape(d.operand) + ")";
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			const pos = d.isPrefix ? "pre" : "post";
			return k + "[" + d.updateOp + "/" + pos + "](" + astShape(d.updateArg) + ")";
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			return k + "(" + astShape(d.callee) + "|" + shapeList(d.arguments) + ")";
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			const op = d.isOptional ? "?." : ".";
			return k + "[" + op + d.property + "](" + astShape(d.object) + ")";
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			return k + "(" + astShape(d.array) + "[" + astShape(d.index) + "])";
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let s = k + "{";
			for (let i = 0; i < d.keys.length; i = i + 1) {
				if (i > 0) s = s + ",";
				s = s + d.keys[i] + ":" + astShape(d.properties[i]);
			}
			return s + "}";
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			return k + "[" + shapeList(d.elements) + "]";
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			let params = "";
			for (let i = 0; i < d.arrowParams.length; i = i + 1) {
				if (i > 0) params = params + ",";
				params = params + d.arrowParams[i] + ":" + d.arrowParamTypes[i];
				if (i < d.arrowDefaults.length && d.arrowDefaults[i] !== null) {
					params = params + "=" + astShape(d.arrowDefaults[i]);
				}
			}
			return k + "[" + d.arrowFlags + "](" + params + "):" + d.arrowReturnType + "=>" + astShape(d.arrowBody) + ")";
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			return k + "(" + astShape(d.ternaryCondition) + "?" + astShape(d.ternaryConsequent) + ":" + astShape(d.ternaryAlternate) + ")";
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			let ps = "";
			for (let i = 0; i < d.funcExprParams.length; i = i + 1) {
				if (i > 0) ps = ps + ",";
				ps = ps + d.funcExprParams[i] + ":" + d.funcExprParamTypes[i];
			}
			return k + "[" + d.funcExprFlags + "](" + ps + "):" + d.funcExprReturnType + "(" + astShape(d.funcExprBody) + ")";
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			return k + "(" + astShape(d.spreadArg) + ")";
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			const ta = node.typeArg !== "" ? "<" + node.typeArg + ">" : "";
			return k + ta + "(" + astShape(d.newCallee) + "|" + shapeList(d.newArguments) + ")";
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			return k + "[as " + d.asType + "](" + astShape(d.asExpr) + ")";
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			const c = d.hasCatch ? "/catch:" + astShape(d.catchVal) : "";
			return k + "(" + astShape(d.tryArg) + c + ")";
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			return k + "(" + astShape(d.matchDisc) + "|" + shapeList(d.matchCases) + ")";
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			const g = d.caseGuard !== null ? "?" + astShape(d.caseGuard) : "";
			return k + "(" + shapeList(d.casePatterns) + g + "=>" + astShape(d.caseBody) + ")";
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			return k + "(" + astShape(d.awaitArg) + ")";
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			return k + (d.isDelegate ? "*" : "") + "(" + astShape(d.yieldArg) + ")";
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			return k + "(" + astShape(d.moveArg) + ")";
		},

		// --- Statement nodes ---
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			return k + "(" + astShape(d.expr) + ")";
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			return k + "(" + astShape(d.argument) + ")";
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return k + "(" + astShape(d.condition) + "," + astShape(d.consequent) + "," + astShape(d.alternate) + ")";
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return k + "(" + astShape(d.whileCondition) + "," + astShape(d.whileBody) + ")";
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			return k + "(" + astShape(d.forInit) + ";" + astShape(d.forCondition) + ";" + astShape(d.forUpdate) + "," + astShape(d.forBody) + ")";
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			const c = d.forOfIsConst ? "const " : "let ";
			return k + "[" + c + d.forOfBinding + "](" + astShape(d.forOfIterable) + "," + astShape(d.forOfBody) + ")";
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			return k + "(" + astShape(d.doBody) + "," + astShape(d.doCondition) + ")";
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			return k + "{" + shapeList(d.statements) + "}";
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			return k + "[" + d.declKind.toString() + " " + d.declName + ":" + d.declType + "](" + astShape(d.initializer) + ")";
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			let ps = "";
			for (let i = 0; i < d.params.length; i = i + 1) {
				if (i > 0) ps = ps + ",";
				ps = ps + d.params[i] + ":" + d.fnParamTypes[i];
				if (i < d.fnDefaults.length && d.fnDefaults[i] !== null) {
					ps = ps + "=" + astShape(d.fnDefaults[i]);
				}
			}
			return k + "[" + d.fnFlags + " " + d.fnName + "(" + ps + "):" + d.fnReturnType + "](" + astShape(d.fnBody) + ")";
		},
		NodeKind.ImportDecl => {
			const d = node.data as ImportDeclData;
			let names = "";
			for (let i = 0; i < d.importNames.length; i = i + 1) {
				if (i > 0) names = names + ",";
				const alias = d.importAliases[i];
				if (alias !== "" && alias !== d.importNames[i]) {
					names = names + d.importNames[i] + " as " + alias;
				} else {
					names = names + d.importNames[i];
				}
			}
			return k + "[" + names + " from " + d.importSource + "]";
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			return k + "(" + astShape(d.exportedDecl) + ")";
		},
		NodeKind.TypeAliasDecl => {
			const d = node.data as TypeAliasDeclData;
			const distinct = d.aliasIsDistinct ? "distinct " : "";
			const generics = d.aliasGenericParams !== "" ? "<" + d.aliasGenericParams + ">" : "";
			if (d.discriminantName !== "" && d.discriminantName !== null) {
				let variants = "";
				for (let i = 0; i < d.variantKeys.length; i = i + 1) {
					if (i > 0) variants = variants + ",";
					variants = variants + d.variantKeys[i] + "=>" + d.variantTypes[i];
				}
				return k + "[" + distinct + d.aliasName + generics + " match " + d.discriminantName + ":" + d.discriminantType + "{" + variants + "}]";
			}
			return k + "[" + distinct + d.aliasName + generics + "=" + d.aliasType + "]";
		},
		NodeKind.EnumDecl => {
			const d = node.data as EnumDeclData;
			let mems = "";
			for (let i = 0; i < d.enumMembers.length; i = i + 1) {
				if (i > 0) mems = mems + ",";
				mems = mems + d.enumMembers[i] + "=" + d.enumValues[i].toString();
			}
			return k + "[" + d.enumName + "{" + mems + "}]";
		},
		NodeKind.InterfaceDecl => {
			const d = node.data as InterfaceDeclData;
			const g = getGenericDecl(d.interfaceName);
			const generics = g !== "" ? "<" + g + ">" : "";
			let fs = "";
			for (let i = 0; i < d.interfaceFields.length; i = i + 1) {
				if (i > 0) fs = fs + ",";
				fs = fs + d.interfaceFields[i] + ":" + d.interfaceFieldTypes[i];
			}
			return k + "[" + d.interfaceName + generics + "{" + fs + "}]";
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			const g = getGenericDecl(d.className);
			const generics = g !== "" ? "<" + g + ">" : "";
			return k + "[" + d.className + generics + " extends " + d.classExtends + "{" + shapeList(d.classBody) + "}]";
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			return k + "[" + d.actorName + "{" + shapeList(d.actorBody) + "}]";
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			const stat = d.propIsStatic ? "static " : "";
			const ro = d.propIsReadonly ? "readonly " : "";
			const vis = d.propVisibility !== "" ? d.propVisibility + " " : "";
			return k + "[" + vis + stat + ro + d.propName + ":" + d.propType + "](" + astShape(d.propInitializer) + ")";
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			const stat = d.methodIsStatic ? "static " : "";
			const vis = d.methodVisibility !== "" ? d.methodVisibility + " " : "";
			let ps = "";
			for (let i = 0; i < d.methodParams.length; i = i + 1) {
				if (i > 0) ps = ps + ",";
				ps = ps + d.methodParams[i] + ":" + d.methodParamTypes[i];
			}
			return k + "[" + d.methodFlags + " " + vis + stat + d.methodName + "(" + ps + "):" + d.methodReturnType + "](" + astShape(d.methodBody) + ")";
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			return k + "(" + astShape(d.throwArg) + ")";
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return k + "[" + d.catchName + "](" + astShape(d.tryBody) + "," + astShape(d.catchBody) + "," + astShape(d.finallyBody) + ")";
		},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			return k + "{" + shapeList(d.programStmts) + "}";
		},

		// Fallback: kind only — sufficient for kinds we don't yet decompose.
		// Tests exercising un-decomposed kinds may need this list extended.
		_ => k,
	};
}

function shapeList(nodes: Node[]): string {
	let s = "";
	for (let i = 0; i < nodes.length; i = i + 1) {
		if (i > 0) s = s + ",";
		s = s + astShape(nodes[i]);
	}
	return s;
}

// Run source through fmt and assert AST shape is preserved.
// Throws (via assert false) with a diff dump on mismatch.
//
// resetAllSideChannels() is called before each parse so that generic
// declarations (stored in a side-channel keyed by name) are captured
// freshly for each version. Without the reset, the comparator can't
// notice if the formatted output dropped generic params on a class
// or interface — both parses would query the same accumulated store.
export function assertFmtPreservesAst(source: string): void {
	resetAllSideChannels();
	const parsedA = parseSource(source);
	if (!parsedA.ok) {
		console.log("INPUT FAILED TO PARSE: " + parsedA.error);
		console.log("source: " + source);
		assert false;
		return;
	}
	const shapeA = astShape(parsedA.value);

	resetAllSideChannels();
	const formatted = fmt(source);
	if (formatted === "") {
		console.log("FMT FAILED");
		console.log("source: " + source);
		assert false;
		return;
	}

	resetAllSideChannels();
	const parsedB = parseSource(formatted);
	if (!parsedB.ok) {
		console.log("FORMATTED OUTPUT FAILED TO PARSE: " + parsedB.error);
		console.log("source:    " + source);
		console.log("formatted: " + formatted);
		assert false;
		return;
	}
	const shapeB = astShape(parsedB.value);

	if (shapeA !== shapeB) {
		console.log("AST SHAPE DIVERGED");
		console.log("source:    " + source);
		console.log("formatted: " + formatted);
		console.log("before:    " + shapeA);
		console.log("after:     " + shapeB);
		assert false;
	}
}

// Visual-quality assertion: formatted output must contain the expected
// substring exactly. Used to test "stays on one line when fits" patterns
// that AST-shape comparison can't catch (line-break decisions).
export function assertFmtContains(source: string, expected: string): void {
	const formatted = fmt(source);
	if (formatted === "") {
		console.log("FMT FAILED");
		console.log("source: " + source);
		assert false;
		return;
	}
	if (!formatted.contains(expected)) {
		console.log("FMT MISSING SUBSTRING");
		console.log("source:    " + source);
		console.log("formatted: " + formatted);
		console.log("expected:  " + expected);
		assert false;
	}
}

// Sanity: simple variable decl already works (no parens issues).
test "fmt roundtrip: simple variable decl" {
	assertFmtPreservesAst("const a = 1;");
}

// Sanity: simple member access (no parens issue).
test "fmt roundtrip: simple member access" {
	assertFmtPreservesAst("const a = obj.field;");
}
