// JavaScript Codegen — Expression Emitters

import {
	Node, NodeKind, NodeFlag, TypeKind, Symbol, SymbolKind,
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
import { emit, emitNode, mark, markNamed, JSGenerator, escapeJSString, emitJoinedStrings, emitJoinedNodes, jsTypedArrayName, recordNeededImport, moduleExportsName, needsAutoAsync } from "./emit";
import { mangledFunctionName, mangledGlobalName, isModuleGlobalVar, resolveOverloadWinner } from "../c/names";
import { emitCopyOnRead } from "./valueCopy";
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
	if (d.bigintValue.byteLength > 0 && d.bigintValue.byteAt(0) === "-".code) {
		emit(gen, "(");
		emit(gen, d.bigintValue);
		emit(gen, ")");
	} else {
		emit(gen, d.bigintValue);
	}
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
export function jsSymbolName(gen: JSGenerator, sym: Symbol | null, name: string): string {
	if (sym === null) return safeJsName(name);
	if (sym.nativeName !== null && sym.nativeName !== "") return safeJsName(name);
	if (gen.multiFile) return jsMultiFileName(gen, sym, name);
	if (!gen.bundleMode && (hasFlag(sym, SymbolFlag.Exported) || hasFlag(sym, SymbolFlag.Imported))) return safeJsName(name);
	if (sym.symbolKind === SymbolKind.Function && sym.modulePath !== null && sym.modulePath !== "") {
		return mangledFunctionName(sym, name, sym.overloadIdx);
	}
	if (sym.symbolKind === SymbolKind.Class && sym.modulePath !== null && sym.modulePath !== "") {
		return mangledGlobalName(sym, name);
	}
	if (isModuleGlobalVar(sym)) return mangledGlobalName(sym, name);
	return safeJsName(name);
}

function moduleCountExporting(gen: JSGenerator, baseName: string): int32 {
	let count = 0;
	for (let mi = 0; mi < gen.modExportKeys.length; mi += 1) {
		const names = gen.modExportVals[mi];
		for (let ni = 0; ni < names.length; ni += 1) {
			if (names[ni] === baseName) { count += 1; break; }
		}
	}
	return count;
}

function exportersBefore(gen: JSGenerator, modulePath: string, baseName: string): int32 {
	let before = 0;
	for (let mi = 0; mi < gen.modExportKeys.length; mi += 1) {
		const names = gen.modExportVals[mi];
		let exports = false;
		for (let ni = 0; ni < names.length; ni += 1) {
			if (names[ni] === baseName) { exports = true; break; }
		}
		if (!exports) continue;
		if (gen.modExportKeys[mi] === modulePath) { return before; }
		before += 1;
	}
	return -1;
}

// Multi-file naming derives from the module's export surface, NOT from
// Exported/Imported symbol flags: registry clones on the importing side can
// arrive with no flags at all, while the declaring side sees flagged symbols —
// flag-based branching makes the two sides disagree. mod.exportNames is the
// same list on both sides. Overload sets append the slot (`f_u0`/`f_u1`)
// because ES modules cannot export two bindings under one name; sole functions
// keep the source name. Non-exported module-level symbols keep the bundle
// mangling — generic instances share a post-mono name (`wrap__int32`) across
// owners, so the module qualifier is what keeps them unique.
// Binding names the emitted tree must never claim: a module that exports a
// class named after a JS global would shadow it file-wide in every importer
// (ESM imports hoist), breaking native extern patterns like `Math.floor(#)`.
const jsGlobalNames: string[] = [
	"Math", "JSON", "Date", "Number", "Boolean", "String", "Object", "Array",
	"Symbol", "Promise", "Map", "Set", "WeakMap", "WeakSet", "Error",
	"TypeError", "RangeError", "SyntaxError", "RegExp", "BigInt", "Proxy",
	"Reflect", "ArrayBuffer", "DataView", "Uint8Array", "Int32Array",
	"Float64Array", "Function", "globalThis", "console", "process", "Buffer",
	"fetch", "URL", "URLSearchParams", "TextEncoder", "TextDecoder", "crypto",
	"performance", "WebSocket", "Blob", "Headers", "Request", "Response",
	"AbortController", "Event", "EventTarget",
];

function isJsGlobalName(name: string): boolean {
	for (const g of jsGlobalNames) {
		if (g === name) return true;
	}
	return false;
}

function exportedBindingName(baseName: string): string {
	return isJsGlobalName(baseName) ? `${safeJsName(baseName)}_u0` : safeJsName(baseName);
}

function jsMultiFileName(gen: JSGenerator, sym: Symbol, name: string): string {
	const baseName = (sym.originalName !== null && sym.originalName !== "") ? sym.originalName : name;
	const hasModule = sym.modulePath !== null && sym.modulePath !== "";
	// The declaring side sees its own symbols without a modulePath while the
	// referencing side sees registry clones that carry one; naming must not
	// depend on which side asks, so empty resolves to the module being emitted.
	const effPath = hasModule ? sym.modulePath : gen.currentModulePath;
	let emitted = "";
	if (sym.symbolKind === SymbolKind.EnumMember && hasModule) {
		// Checker lowers E.Member to a flat E_Member identifier; the emitted
		// enum declaration exports exactly those flat names.
		emitted = safeJsName(name);
		if (sym.modulePath !== gen.currentModulePath) recordNeededImport(gen, sym.modulePath, emitted);
		return emitted;
	}
	if (sym.symbolKind === SymbolKind.Function) {
		if (moduleExportsName(gen, effPath, baseName)) {
			const inSet = sym.overloadIdx > 0 || (sym.overloads !== null && sym.overloads.length > 0);
			// The declaring side compiles alone, so a set spanning modules
			// never shows in its symbol state — both sides read the collision
			// off the export surface instead, the one list they share.
			let slot = sym.overloadIdx;
			let suffixed = inSet;
			if (moduleCountExporting(gen, baseName) > 1) {
				const before = exportersBefore(gen, effPath, baseName);
				if (before >= 0) { slot = before + sym.overloadIdx; suffixed = true; }
			}
			emitted = suffixed ? `${safeJsName(baseName)}_u${slot}` : exportedBindingName(baseName);
		} else if (hasModule) {
			emitted = mangledFunctionName(sym, name, sym.overloadIdx);
		} else {
			return safeJsName(name);
		}
	} else if (sym.symbolKind === SymbolKind.Class) {
		if (moduleExportsName(gen, effPath, baseName)) {
			emitted = exportedBindingName(baseName);
		} else if (hasModule) {
			emitted = mangledGlobalName(sym, name);
		} else {
			return safeJsName(name);
		}
	} else if (isModuleGlobalVar(sym)) {
		emitted = moduleExportsName(gen, sym.modulePath, baseName) ? safeJsName(baseName) : mangledGlobalName(sym, name);
	} else {
		return safeJsName(name);
	}
	if (effPath !== gen.currentModulePath) recordNeededImport(gen, effPath, emitted);
	return emitted;
}

export function emitIdentifier(gen: JSGenerator, node: Node): void {
	const d = node.data as IdentifierData;
	if (d.name === "this") { emit(gen, gen.thisName); return; }
	// The name recorded at a call site is what a debugger shows as the name of
	// the frame it enters, so a renamed callee has to carry its .ms name here.
	const emitted = jsSymbolName(gen, node.resolvedSym, d.name);
	if (emitted !== d.name) markNamed(gen, node, d.name);
	emit(gen, emitted);
}

// ===== Binary Expression =====

export function emitBinaryExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as BinaryExprData;
	// Assignment doesn't need outer parens
	if (d.operator === "=") {
		emitNode(gen, d.left);
		emit(gen, " = ");
		emitCopyOnRead(gen, d.right);
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

// A MemberExpr's own location is its dot; the callee's first token lives on
// the leftmost object, which is where a debugger expects the call to start.
function calleeOriginNode(callee: Node): Node {
	let origin = callee;
	while (origin.kind === NodeKind.MemberExpr) {
		origin = (origin.data as MemberExprData).object;
	}
	return origin;
}

export function emitCallExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as CallExprData;

	if (d.callee.kind === NodeKind.Identifier
			&& (d.callee.data as IdentifierData).name === "super"
			&& d.callee.resolvedSym !== null) {
		mark(gen, d.callee);
		emit(gen, "super(");
		emitJoinedNodes(gen, d.arguments, ", ");
		emit(gen, ")");
		return;
	}

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
		markNamed(gen, calleeOriginNode(d.callee), sym.name);
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
		markNamed(gen, calleeOriginNode(d.callee), isMsPrintln ? "msPrintln" : "console.log");
		emit(gen, "console.log(");
		emitJoinedNodes(gen, d.arguments, ", ");
		emit(gen, ")");
		return;
	}

	// Overloaded call — bind the check-time winner; the identifier's own
	// resolvedSym is always the primary.
	if (d.callee.kind === NodeKind.Identifier && sym !== null
			&& sym.overloads !== null && sym.overloads.length > 0) {
		const w = resolveOverloadWinner(sym, d.resolvedOverloadIdx);
		const ws = w.winnerSym;
		if (ws !== null && ws.nativeName !== "" && hasNativePattern(ws.nativeName)) {
			markNamed(gen, d.callee, ws.name);
			emitNativePattern(gen, ws.nativeName, d.arguments, ws.name);
			return;
		}
		markNamed(gen, d.callee, (d.callee.data as IdentifierData).name);
		emit(gen, jsSymbolName(gen, ws, (d.callee.data as IdentifierData).name));
		emit(gen, "(");
		emitJoinedNodes(gen, d.arguments, ", ");
		emit(gen, ")");
		return;
	}

	const memberOverloadSym = node.resolvedSym;
	if (d.callee.kind === NodeKind.MemberExpr && memberOverloadSym !== null
			&& memberOverloadSym.overloadIdx > 0
			&& memberOverloadSym.declNode !== null
			&& memberOverloadSym.declNode.kind === NodeKind.MethodDecl) {
		const mem = d.callee.data as MemberExprData;
		emitNode(gen, mem.object);
		emit(gen, mem.isOptional ? "?." : ".");
		emit(gen, jsMethodMemberName(mem.property, memberOverloadSym));
		emit(gen, "(");
		emitJoinedNodes(gen, d.arguments, ", ");
		emit(gen, ")");
		return;
	}

	// Wrap a function-expression callee: (() => 5)()
	const wrapCallee = d.callee.kind === NodeKind.ArrowFunction || d.callee.kind === NodeKind.FunctionExpr;
	if (wrapCallee) {
		emit(gen, "(");
		emitNode(gen, d.callee);
		emit(gen, ")");
	} else {
		emitNode(gen, d.callee);
	}
	emit(gen, "(");
	emitJoinedNodes(gen, d.arguments, ", ");
	emit(gen, ")");
}

// ===== Member Expression =====

export function jsMethodMemberName(methodName: string, sym: Symbol | null): string {
	if (sym === null || sym.overloadIdx <= 0) return methodName;
	return `${methodName}_u${sym.overloadIdx}`;
}

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
	if ((node.flags & NodeFlag.Closure) !== 0) {
		for (let i = 0; i < d.keys.length; i += 1) {
			if (d.keys[i] === "fn" && i < d.properties.length) {
				emitNode(gen, d.properties[i]);
				return;
			}
		}
	}
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
			emitCopyOnRead(gen, d.properties[i]);
		}
	}
	emit(gen, " }");
}

// ===== Array Literal =====

export function emitArrayLiteral(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrayLiteralData;
	const t = node.nodeType;
	let typedName = "";
	if (t !== null && t.kind === TypeKind.SizedArray && t.typeReturn !== null) {
		typedName = jsTypedArrayName(t.typeReturn.kind);
	}
	if (typedName !== "") emit(gen, "new " + typedName + "(");
	emit(gen, "[");
	for (let i = 0; i < d.elements.length; i += 1) {
		if (i > 0) emit(gen, ", ");
		emitCopyOnRead(gen, d.elements[i]);
	}
	emit(gen, "]");
	if (typedName !== "") emit(gen, ")");
}

// ===== Arrow Function =====

export function emitArrowFunction(gen: JSGenerator, node: Node): void {
	const d = node.data as ArrowFunctionData;
	const isAsync = d.arrowFlags === "async" || d.arrowFlags === "async_generator" || needsAutoAsync(d.arrowFlags, d.arrowBody);
	if (isAsync) { emit(gen, "async "); }
	if (d.arrowParams.length === 1 && !isAsync) {
		emit(gen, d.arrowParams[0]);
	} else {
		emit(gen, "(");
		emitJoinedStrings(gen, d.arrowParams, ", ");
		emit(gen, ")");
	}
	emit(gen, " => ");
	if (d.arrowBody.kind === NodeKind.ObjectLiteral) {
		emit(gen, "(");
		emitNode(gen, d.arrowBody);
		emit(gen, ")");
	} else {
		emitNode(gen, d.arrowBody);
	}
}

// ===== Function Expression =====

export function emitFunctionExpr(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionExprData;
	const autoAsync = needsAutoAsync(d.funcExprFlags, d.funcExprBody);
	match (d.funcExprFlags) {
		"async" => { emit(gen, "async function("); },
		"generator" => { emit(gen, autoAsync ? "async function*(" : "function*("); },
		"async_generator" => { emit(gen, "async function*("); },
		_ => { emit(gen, autoAsync ? "async function(" : "function("); },
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
