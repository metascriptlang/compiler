// JavaScript Codegen — Expression Emitters

import {
	Node, NodeKind, Symbol, SymbolKind,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BigIntLiteralData, RegexLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData,
	ArrowFunctionData, FunctionExprData,
	TypeAssertionData, ConditionalExprData,
	SpreadExprData, NewExprData, MoveExprData,
	AwaitExprData, YieldExprData,
} from "../../ast/node";
import { emit, emitNode, JSGenerator, escapeJSString, emitJoinedStrings, emitJoinedNodes } from "./emit";
import { mangledFunctionName, mangledGlobalName, isModuleGlobalVar } from "../c/names";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { int64ToDecimal } from "../../utils/string";

// ===== Literal Emitters =====

export function emitNumberLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as NumberLiteralData;
	// Integers print from the exact int64. The engine still parses the result as
	// a double — exact int64 SEMANTICS on this backend need the BigInt mapping —
	// but emitting the digits the user wrote keeps the loss in one place instead
	// of baking a second, front-end rounding into the output.
	const text = d.isFloat ? "" + d.value : int64ToDecimal(d.intVal);
	if (text.byteLength > 0 && text.byteAt(0) === "-".code) {
		emit(gen, "(");
		emit(gen, text);
		emit(gen, ")");
	} else {
		emit(gen, text);
	}
}

export function emitStringLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as StringLiteralData;
	emit(gen, "\"");
	emit(gen, escapeJSString(d.value));
	emit(gen, "\"");
}

export function emitBooleanLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as BooleanLiteralData;
	if (d.boolValue) {
		emit(gen, "true");
	} else {
		emit(gen, "false");
	}
}

export function emitNullLiteral(gen: JSGenerator, node: Node): void {
	emit(gen, "null");
}

export function emitBigIntLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as BigIntLiteralData;
	emit(gen, d.bigintValue);
}

export function emitRegexLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as RegexLiteralData;
	emit(gen, d.regexPattern);
}

// ===== Identifier =====

// JS reserved words — HashSet<string> for O(1) lookup.
const JS_RESERVED: HashSet<string> = new HashSet<string>([
	"abstract", "arguments", "await", "boolean", "break", "byte",
	"case", "catch", "char", "class", "const", "continue", "debugger",
	"default", "delete", "do", "double", "else", "enum", "eval", "export", "extends",
	"false", "final", "finally", "float", "for", "function", "goto", "if",
	"implements", "import", "in", "instanceof", "int", "interface", "let",
	"long", "native", "new", "null", "package", "private", "protected",
	"public", "return", "short", "static", "switch", "synchronized",
	"throw", "throws", "transient", "true", "try", "typeof", "var",
	"void", "volatile", "while", "with", "yield",
]);

export function safeJsName(name: string): string {
	if (JS_RESERVED.has(name)) return "$" + name;
	// Operator names (==, <, !=, etc.) — mangle to valid JS identifier
	if (name.length > 0 && name.byteAt(0) !== "_".code
		&& name.byteAt(0) !== "$".code
		&& !(name.byteAt(0) >= "a".code && name.byteAt(0) <= "z".code)
		&& !(name.byteAt(0) >= "A".code && name.byteAt(0) <= "Z".code)) {
		let mangled = "$op_";
		let i = 0;
		while (i < name.byteLength) {
			mangled = mangled + match (name.byteAt(i)) {
				"=".code => "eq",
				"!".code => "bang",
				"<".code => "lt",
				">".code => "gt",
				"+".code => "plus",
				"-".code => "minus",
				"*".code => "star",
				"/".code => "slash",
				"%".code => "pct",
				"[".code => "lbr",
				"]".code => "rbr",
				_ => "",
			};
			i = i + 1;
		}
		return mangled;
	}
	return name;
}

// Decl and every reference derive the emitted name from the SAME symbol, so
// they agree by construction. Uniqueness is required within the EMITTED scope:
// the bundle is one flat scope (mangle everything), while non-bundle emits one
// ES module per file where the import/export pair binds public names.
export function jsSymbolName(sym: Symbol, name: string, bundleMode: boolean): string {
	if (sym === null) return safeJsName(name);
	if (sym.nativeName !== null && sym.nativeName !== "") return safeJsName(name);
	if (!bundleMode && (hasFlag(sym, SymbolFlag.Exported) || hasFlag(sym, SymbolFlag.Imported))) return safeJsName(name);
	if (sym.symbolKind === SymbolKind.Function && sym.modulePath !== null && sym.modulePath !== "") {
		return mangledFunctionName(sym, name, sym.overloadIdx);
	}
	if (sym.symbolKind === SymbolKind.Class && sym.modulePath !== null && sym.modulePath !== "") {
		return mangledGlobalName(sym, name);
	}
	if (isModuleGlobalVar(sym)) return mangledGlobalName(sym, name);
	return safeJsName(name);
}

export function emitIdentifier(gen: JSGenerator, node: Node): void {
	const d = node.data as IdentifierData;
	if (d.name === "this") { emit(gen, gen.thisName); return; }
	emit(gen, jsSymbolName(node.resolvedSym, d.name, gen.bundleMode));
}

// ===== Binary Expression =====

export function emitBinaryExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as BinaryExprData;
	// Assignment doesn't need outer parens
	if (d.operator === "=") {
		emitNode(gen, d.left);
		emit(gen, " = ");
		emitNode(gen, d.right);
	} else if (d.operator === "+=" || d.operator === "-=" || d.operator === "*=" || d.operator === "/=" || d.operator === "%=") {
		emitNode(gen, d.left);
		emit(gen, " ");
		emit(gen, d.operator);
		emit(gen, " ");
		emitNode(gen, d.right);
	} else {
		emit(gen, "(");
		emitNode(gen, d.left);
		emit(gen, " ");
		emit(gen, d.operator);
		emit(gen, " ");
		emitNode(gen, d.right);
		emit(gen, ")");
	}
}

// ===== Unary Expression =====

export function emitUnaryExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as UnaryExprData;
	if (d.unaryOp === "&") {
		// Address-of: no-op in JS (arrays/strings are already references)
		emitNode(gen, d.operand);
	} else if (d.unaryOp === "typeof") {
		emit(gen, "typeof ");
		emitNode(gen, d.operand);
	} else {
		emit(gen, d.unaryOp);
		emitNode(gen, d.operand);
	}
}

// ===== Update Expression =====

export function emitUpdateExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as UpdateExprData;
	if (d.isPrefix) {
		emit(gen, d.updateOp);
		emitNode(gen, d.updateArg);
	} else {
		emitNode(gen, d.updateArg);
		emit(gen, d.updateOp);
	}
}

// ===== Call Expression =====

// Native-binding pattern substitution — reference parity: jsgen.nim importjs.
// A symbol's `nativeName` is a JS template with placeholders:
//   #   consume next arg          @   splat remaining args         $1  symbol name
// Used by extern functions in .jms preludes (e.g.
// `extern function set<K,V>(this m, k, v) from "#.set(#, #)"`) to bind MS
// extension calls to native JS dispatch without wrapper functions or mangling.
function hasNativePattern(s: string): boolean {
	for (let i = 0; i < s.length; i += 1) {
		const c = s.charAt(i);
		if (c === "#" || c === "@") return true;
		if (c === "$" && i + 1 < s.length && s.charAt(i + 1) === "1") return true;
	}
	return false;
}

function emitNativePattern(gen: JSGenerator, pattern: string, args: Node[], symName: string): void {
	let argIdx = 0;
	let i = 0;
	while (i < pattern.length) {
		const ch = pattern.charAt(i);
		if (ch === "#") {
			if (argIdx < args.length) {
				emitNode(gen, args[argIdx]);
				argIdx = argIdx + 1;
			}
			i = i + 1;
		} else if (ch === "@") {
			let first = true;
			while (argIdx < args.length) {
				if (!first) emit(gen, ", ");
				emitNode(gen, args[argIdx]);
				argIdx = argIdx + 1;
				first = false;
			}
			i = i + 1;
		} else if (ch === "$" && i + 1 < pattern.length && pattern.charAt(i + 1) === "1") {
			emit(gen, symName);
			i = i + 2;
		} else {
			emit(gen, ch);
			i = i + 1;
		}
	}
}

export function emitCallExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as CallExprData;

	// Native pattern dispatch — runs before name-based emit so the callee's
	// mangled / Identifier name is replaced by the JS template. For MemberExpr
	// callees (extern class methods where extensionMethodLower skipped), the
	// receiver is prepended to match the post-lower arg shape used by free
	// extension functions.
	const sym = d.callee.resolvedSym;
	if (sym !== null && sym.nativeName !== "" && hasNativePattern(sym.nativeName)) {
		let patternArgs = d.arguments;
		if (d.callee.kind === NodeKind.MemberExpr) {
			patternArgs = [(d.callee.data as MemberExprData).object];
			for (const a of d.arguments) patternArgs.push(a);
		}
		emitNativePattern(gen, sym.nativeName, patternArgs, sym.name);
		return;
	}

	// msPrintln / console.log → console.log (strings are native)
	const isMsPrintln = d.callee.kind === NodeKind.Identifier && (d.callee.data as IdentifierData).name === "msPrintln";
	const isConsoleLog = d.callee.kind === NodeKind.MemberExpr
		&& (d.callee.data as MemberExprData).property === "log"
		&& (d.callee.data as MemberExprData).object.kind === NodeKind.Identifier
		&& ((d.callee.data as MemberExprData).object.data as IdentifierData).name === "console";
	if (isMsPrintln || isConsoleLog) {
		emit(gen, "console.log(");
		emitJoinedNodes(gen, d.arguments, ", ");
		emit(gen, ")");
		return;
	}

	// Regular function call
	emitNode(gen, d.callee);
	emit(gen, "(");
	emitJoinedNodes(gen, d.arguments, ", ");
	emit(gen, ")");
}

// ===== Member Expression =====

export function emitMemberExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as MemberExprData;
	// Wrap number literals: (42).toString()
	if (d.object.kind === NodeKind.NumberLiteral) {
		emit(gen, "(");
		emitNode(gen, d.object);
		emit(gen, ")");
	} else {
		emitNode(gen, d.object);
	}
	if (d.isOptional) {
		emit(gen, "?.");
	} else {
		emit(gen, ".");
	}
	emit(gen, d.property);
}

// ===== Array Access =====

export function emitArrayAccess(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrayAccessData;
	emitNode(gen, d.array);
	emit(gen, "[");
	emitNode(gen, d.index);
	emit(gen, "]");
}

// ===== Object Literal =====

export function emitObjectLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as ObjectLiteralData;
	if (d.keys.length === 0) {
		emit(gen, "{}");
		return;
	}
	emit(gen, "{ ");
	for (let i = 0; i < d.keys.length; i += 1) {
		if (i > 0) emit(gen, ", ");
		emit(gen, d.keys[i]);
		emit(gen, ": ");
		if (i < d.properties.length) {
			emitNode(gen, d.properties[i]);
		}
	}
	emit(gen, " }");
}

// ===== Array Literal =====

export function emitArrayLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrayLiteralData;
	emit(gen, "[");
	emitJoinedNodes(gen, d.elements, ", ");
	emit(gen, "]");
}

// ===== Arrow Function =====

export function emitArrowFunction(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrowFunctionData;
	const isAsync = d.arrowFlags === "async" || d.arrowFlags === "async_generator";
	if (isAsync) { emit(gen, "async "); }
	if (d.arrowParams.length === 1 && !isAsync) {
		emit(gen, d.arrowParams[0]);
	} else {
		emit(gen, "(");
		emitJoinedStrings(gen, d.arrowParams, ", ");
		emit(gen, ")");
	}
	emit(gen, " => ");
	emitNode(gen, d.arrowBody);
}

// ===== Function Expression =====

export function emitFunctionExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionExprData;
	match (d.funcExprFlags) {
		"async" => { emit(gen, "async function("); },
		"generator" => { emit(gen, "function*("); },
		"async_generator" => { emit(gen, "async function*("); },
		_ => { emit(gen, "function("); },
	};
	emitJoinedStrings(gen, d.funcExprParams, ", ");
	emit(gen, ") ");
	emitNode(gen, d.funcExprBody);
}

// ===== Conditional Expression =====

export function emitConditionalExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as ConditionalExprData;
	emit(gen, "(");
	emitNode(gen, d.ternaryCondition);
	emit(gen, " ? ");
	emitNode(gen, d.ternaryConsequent);
	emit(gen, " : ");
	emitNode(gen, d.ternaryAlternate);
	emit(gen, ")");
}

// ===== Spread Expression =====

export function emitSpreadExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as SpreadExprData;
	emit(gen, "...");
	emitNode(gen, d.spreadArg);
}

// ===== New Expression =====

export function emitNewExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as NewExprData;
	emit(gen, "new ");
	emitNode(gen, d.newCallee);
	emit(gen, "(");
	emitJoinedNodes(gen, d.newArguments, ", ");
	emit(gen, ")");
}

// ===== Type Assertion (no-op in JS) =====

export function emitTypeAssertion(gen: JSGenerator, node: Node): void {
	const d = node.data as TypeAssertionData;
	emitNode(gen, d.asExpr);
}

// ===== Move Expression (no-op in JS) =====

export function emitMoveExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as MoveExprData;
	emitNode(gen, d.moveArg);
}

// ===== Await Expression (fallback if not lowered) =====

export function emitAwaitExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as AwaitExprData;
	emit(gen, "await ");
	emitNode(gen, d.awaitArg);
}

// ===== Yield Expression (fallback if not lowered) =====

export function emitYieldExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as YieldExprData;
	if (d.isDelegate) {
		emit(gen, "yield* ");
	} else {
		emit(gen, "yield ");
	}
	emitNode(gen, d.yieldArg);
}
