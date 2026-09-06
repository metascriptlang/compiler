// Printer — transforms MetaScript AST → Doc IR
// Implementation logic follows Biome/Prettier standards (2026).

import { Node, NodeKind } from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docNil, docText, docGroup, docHardLine, docLineSuffix } from "../doc";
import { registerNodePrinter } from "./callbacks";

import {
	printNumberLiteral, printStringLiteral, printBooleanLiteral, printIdentifier,
	printBigIntLiteral, printRegexLiteral,
} from "./literals";
import {
	printBinaryExpr, printUnaryExpr, printUpdateExpr, printCallExpr,
	printMemberExpr, printArrayAccess, printObjectLiteral, printArrayLiteral,
	printArrowFunction, printConditionalExpr, printSpreadExpr, printNewExpr,
	printTypeAssertion, printMatchExpr, printTryExpr, printMoveExpr,
	printOutExpr, printSizeofExpr, printArrayPattern, printObjectPattern,
	printObjectPatternProp, printMacroInvocation, printFunctionExpr,
	printAwaitExpr, printYieldExpr,
} from "./expressions";
import {
	printProgram, printBlock, printVariableDecl, printExprStmt,
	printReturnStmt, printIfStmt, printWhileStmt, printForStmt,
	printForOfStmt, printForInStmt, printDoWhileStmt, printSwitchStmt, printMatchStmt,
	printFunctionDecl, printThrowStmt, printTryCatchStmt, printDeferStmt,
	printBreakStmt, printContinueStmt, printDestructuringDecl,
} from "./statements";
import {
	printImportDecl, printExportDecl, printTypeAliasDecl, printEnumDecl,
	printInterfaceDecl, printStructDecl, printClassDecl, printActorDecl, printExternDecl, printDecoratedDecl,
	printTestDecl, printAssertStmt, printPropertyDecl, printMethodDecl, printConstructorDecl,
	printMacroDecl,
} from "./declarations";

export function printNode(node: Node, options: FormatOptions): Doc {
	if (node == null) return docNil();

	const innerDoc = match (node.kind) {
		// ===== Literals =====
		NodeKind.NumberLiteral => printNumberLiteral(node),
		NodeKind.StringLiteral => printStringLiteral(node, options),
		NodeKind.BooleanLiteral => printBooleanLiteral(node),
		NodeKind.NullLiteral => docText("null"),
		NodeKind.BigIntLiteral => printBigIntLiteral(node),
		NodeKind.RegexLiteral => printRegexLiteral(node),
		NodeKind.Identifier => printIdentifier(node),

		// ===== Expressions =====
		NodeKind.BinaryExpr => printBinaryExpr(node, options),
		NodeKind.UnaryExpr => printUnaryExpr(node, options),
		NodeKind.UpdateExpr => printUpdateExpr(node, options),
		NodeKind.CallExpr => printCallExpr(node, options),
		NodeKind.MemberExpr => printMemberExpr(node, options),
		NodeKind.ArrayAccess => printArrayAccess(node, options),
		NodeKind.ObjectLiteral => printObjectLiteral(node, options),
		NodeKind.ArrayLiteral => printArrayLiteral(node, options),
		NodeKind.ArrowFunction => printArrowFunction(node, options),
		NodeKind.ConditionalExpr => printConditionalExpr(node, options),
		NodeKind.SpreadExpr => printSpreadExpr(node, options),
		NodeKind.NewExpr => printNewExpr(node, options),
		NodeKind.TypeAssertion => printTypeAssertion(node, options),
		NodeKind.MatchExpr => printMatchExpr(node, options),
		NodeKind.TryExpr => printTryExpr(node, options),
		NodeKind.MoveExpr => printMoveExpr(node, options),
		NodeKind.OutExpr => printOutExpr(node, options),
		NodeKind.SizeofExpr => printSizeofExpr(node),
		NodeKind.FunctionExpr => printFunctionExpr(node, options),
		NodeKind.MacroInvocation => printMacroInvocation(node, options),
		NodeKind.AwaitExpr => printAwaitExpr(node, options),
		NodeKind.YieldExpr => printYieldExpr(node, options),

		// ===== Statements =====
		NodeKind.Program => printProgram(node, options),
		NodeKind.BlockStmt => printBlock(node, options),
		NodeKind.VariableDecl => printVariableDecl(node, options),
		NodeKind.ExprStmt => printExprStmt(node, options),
		NodeKind.ReturnStmt => printReturnStmt(node, options),
		NodeKind.IfStmt => printIfStmt(node, options),
		NodeKind.WhileStmt => printWhileStmt(node, options),
		NodeKind.ForStmt => printForStmt(node, options),
		NodeKind.ForOfStmt => printForOfStmt(node, options),
		NodeKind.ForInStmt => printForInStmt(node, options),
		NodeKind.DoWhileStmt => printDoWhileStmt(node, options),
		NodeKind.SwitchStmt => printSwitchStmt(node, options),
		NodeKind.MatchStmt => printMatchStmt(node, options),
		NodeKind.FunctionDecl => printFunctionDecl(node, options),
		NodeKind.ThrowStmt => printThrowStmt(node, options),
		NodeKind.TryCatchStmt => printTryCatchStmt(node, options),
		NodeKind.DeferStmt => printDeferStmt(node, options),
		NodeKind.BreakStmt => printBreakStmt(node),
		NodeKind.ContinueStmt => printContinueStmt(node),
		NodeKind.UnreachableStmt => docText("unreachable;"),

		// ===== Declarations =====
		NodeKind.ImportDecl => printImportDecl(node, options),
		NodeKind.ExportDecl => printExportDecl(node, options),
		NodeKind.TypeAliasDecl => printTypeAliasDecl(node, options),
		NodeKind.EnumDecl => printEnumDecl(node, options),
		NodeKind.InterfaceDecl => printInterfaceDecl(node, options),
		NodeKind.StructDecl => printStructDecl(node, options),
		NodeKind.ClassDecl => printClassDecl(node, options),
		NodeKind.ActorDecl => printActorDecl(node, options),
		NodeKind.ExternDecl => printExternDecl(node, options),
		NodeKind.DecoratedDecl => printDecoratedDecl(node, options),
		NodeKind.TestDecl => printTestDecl(node, options),
		NodeKind.AssertStmt => printAssertStmt(node, options),
		NodeKind.PropertyDecl => printPropertyDecl(node, options),
		NodeKind.MethodDecl => printMethodDecl(node, options),
		NodeKind.ConstructorDecl => printConstructorDecl(node, options),
		NodeKind.MacroDecl => printMacroDecl(node, options),
		NodeKind.ArrayPattern => printArrayPattern(node, options),
		NodeKind.ObjectPattern => printObjectPattern(node, options),
		NodeKind.ObjectPatternProp => printObjectPatternProp(node, options),
		NodeKind.DestructuringDecl => printDestructuringDecl(node, options),

		_ => docText("<unsupported node: " + node.kind.toString() + ">"),
	};

	// Wrap with comments if present.
	// 3 buckets by relative line:
	//   - leading: comment.line < node.line (before)
	//   - trailing: comment.line === node.line (same line, end-of-line comment)
	//   - below: comment.line > node.line (standalone line(s) after the stmt)
	if (node.comments.length > 0) {
		const leading: Doc[] = [];
		const trailing: Doc[] = [];
		const below: Doc[] = [];
		for (const comment of node.comments) {
			if (comment.line < node.location.line) {
				leading.push(docText(comment.value));
				leading.push(docHardLine());
			} else if (comment.line == node.location.line) {
				trailing.push(docLineSuffix([docText(" " + comment.value)]));
			} else {
				below.push(docHardLine());
				below.push(docText(comment.value));
			}
		}
		if (leading.length > 0 || trailing.length > 0 || below.length > 0) {
			const parts: Doc[] = [];
			for (const l of leading) { parts.push(l); }
			parts.push(innerDoc);
			for (const t of trailing) { parts.push(t); }
			for (const b of below) { parts.push(b); }
			return docGroup(parts);
		}
	}

	return innerDoc;
}

// Automatically register on module load
registerNodePrinter(printNode);
