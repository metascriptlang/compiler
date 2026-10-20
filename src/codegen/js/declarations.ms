// JavaScript Codegen — Declaration Emitters

import {
	Node, NodeKind, NodeFlag, DeclKind, TypeKind, FunctionDeclData, EnumDeclData, ClassDeclData, MethodDeclData,
	ConstructorDeclData, ImportDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData, PropertyDeclData, ActorDeclData, ExprStmtData, createNodeAt, SymbolKind,
} from "../../ast/node";
import { emit, emitNode, emitIndent, emitNewline, emitBlockInline, markNamed, JSGenerator, convertImportPath, emitJoinedSafeStrings, emitJoinedSafeParams, emitBodyOrEmpty, lookupImportSpec, needsAutoAsync, escapeJSString, declareBinding } from "./emit";
import { safeJsName, jsSymbolName, jsMethodMemberName } from "./expressions";
import { useActorRuntime } from "./actorMailbox";
import { hasGenericParams, runtimeClassSym, unwrapRef } from "../../checker/types";
import { isGenericFn, routineKindFlag, isExtensionRoutine } from "../../checker/context";
import { jsDefaultValue, emitCopyOnRead } from "./valueCopy";
import { mangleQualified, mangleModuleName } from "../c/names";
import { monoInstanceName } from "../../monomorphize/registry";
import { enumMemberName, hasFlag, SymbolFlag } from "../../checker/symbol";

// ===== Function Declaration =====

function emitFunctionDeclInner(gen: JSGenerator, node: Node): void {
	const d = node.data as FunctionDeclData;
	const autoAsync = needsAutoAsync(d.fnFlags, d.fnBody);
	match (routineKindFlag(d.fnFlags)) {
		"async" => { emit(gen, "async function "); },
		"generator" => { emit(gen, autoAsync ? "async function* " : "function* "); },
		"async_generator" => { emit(gen, "async function* "); },
		_ => { emit(gen, autoAsync ? "async function " : "function "); },
	};
	const fnEmitted = jsSymbolName(gen, node.resolvedSym, d.fnName);
	declareBinding(gen, fnEmitted);
	if (fnEmitted != d.fnName) markNamed(gen, node, d.fnName);
	emit(gen, fnEmitted);
	emit(gen, "(");
	const savedThisName = gen.thisName;
	if (d.params.length > 0 && d.params[0] == "this") { gen.thisName = "$this"; }
	emitJoinedSafeParams(gen, node, d.params, ", ", receiverSafeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.fnBody);
	gen.thisName = savedThisName;
	emitNewline(gen);
}

function receiverSafeJsName(name: string): string {
	return name == "this" ? "$this" : safeJsName(name);
}

// Check if fnFlags contains "extern" (may also have gen:/ext: segments)
function isExternFlag(flags: string): boolean {
	if (flags == "extern") return true;
	if (flags.length < 6) return false;
	// Check for "extern|..." or "...|extern|..." or "...|extern"
	if (flags.startsWith("extern|")) return true;
	if (flags.indexOf("|extern|") >= 0) return true;
	if (flags.endsWith("|extern")) return true;
	return false;
}

function isGenericRoutine(node: Node, flags: string): boolean {
	return isGenericFn(flags) || (node.nodeType != null && hasGenericParams(node.nodeType));
}

function isGenericClass(node: Node): boolean {
	return node.nodeType != null && hasGenericParams(node.nodeType);
}

function isStaticClassState(member: Node): boolean {
	if (member.kind == NodeKind.BlockStmt) return true;
	return member.kind == NodeKind.PropertyDecl && (member.data as PropertyDeclData).propIsStatic;
}

// A generic class's instances are emitted per instantiation; the declaration itself
// keeps only what is shared by every instance: its static state, as a class that holds it.
function classEmitsShell(node: Node): boolean {
	if (!isGenericClass(node)) return true;
	for (const member of (node.data as ClassDeclData).classBody) {
		if (isStaticClassState(member)) return true;
	}
	return false;
}

function emittableFunctionDecl(node: Node): boolean {
	const d = node.data as FunctionDeclData;
	if (isExternFlag(d.fnFlags) || d.fnFlags.indexOf("overload", 0) >= 0 || isGenericFn(d.fnFlags)) return false;
	if (node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.CompileTime)) return false;
	return node.nodeType == null || !hasGenericParams(node.nodeType);
}

export function emitFunctionDecl(gen: JSGenerator, node: Node): void {
	if (!emittableFunctionDecl(node)) return;
	emitIndent(gen);
	emitFunctionDeclInner(gen, node);
}

// ===== Enum Declaration =====

function enumMemberValue(d: EnumDeclData, i: number): number {
	return (d.enumValues != null && i < d.enumValues.length) ? d.enumValues[i] : i;
}

export function jsEnumObject(local: string, d: EnumDeclData): string {
	let out = `const ${local} = {};\n`;
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		const name = escapeJSString(d.enumMembers[i]);
		out = out + `${local}[${local}["${name}"] = ${enumMemberValue(d, i)}] = "${name}";\n`;
	}
	return out;
}

function emitEnumDeclInner(gen: JSGenerator, node: Node, linePrefix: string): void {
	const d = node.data as EnumDeclData;
	// Flat constants matching the checker's `EnumName_Member` rewrite, in both
	// bundle and non-bundle output. The IIFE `E.Member` object form is never
	// referenced — the checker lowers every `E.Member` access to `E_Member`.
	// Honor explicit values (enumValues), else fall back to ordinal index.
	// linePrefix carries `export ` to members past the first — the caller
	// already spent its own `export ` on member zero.
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		if (i > 0) { emitIndent(gen); emit(gen, linePrefix); }
		const member = enumMemberName(node.resolvedSym, safeJsName(d.enumName), d.enumMembers[i]);
		declareBinding(gen, member);
		emit(gen, `var ${member} = ${enumMemberValue(d, i)};\n`);
	}
}

export function emitEnumDecl(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitEnumDeclInner(gen, node, "");
}

// ===== Class Declaration =====

function jsBaseClassName(gen: JSGenerator, node: Node, declaredName: string): string {
	const sym = node.resolvedSym;
	if (sym == null || sym.symbolType == null) return safeJsName(declaredName);
	let inner = sym.symbolType;
	if (inner.kind == TypeKind.Ref && inner.typeReturn != null) inner = inner.typeReturn;
	if (inner.typeExtra == null) return safeJsName(declaredName);
	const parentType = unwrapRef(inner.typeExtra);
	const parent = parentType.kind == TypeKind.GenericInstance || inner.typeExtra.sym == null ? runtimeClassSym(parentType) : inner.typeExtra.sym;
	if (parent == null) return safeJsName(declaredName);
	if (parentType.kind == TypeKind.GenericInstance && !hasGenericParams(parentType)) return jsSymbolName(gen, parent, monoInstanceName(parentType));
	return jsSymbolName(gen, parent, parent.name);
}

// Instance fields are assigned by the constructor, so only a static one carries
// an initializer that nothing else would ever run.
function emitStaticPropertyDecl(gen: JSGenerator, member: Node): void {
	const d = member.data as PropertyDeclData;
	if (!d.propIsStatic || d.propInitializer == null) return;
	emitIndent(gen);
	emit(gen, "static ");
	emit(gen, safeJsName(d.propName));
	emit(gen, " = ");
	emitNode(gen, d.propInitializer);
	emit(gen, ";\n");
}

// A class declaration that produces no JS at all: an `extern class` binds a
// native global, and a class merged onto a callable namespace resolves to the
// prelude function of the same name. Both emitters must agree — the ES-module
// path writes `export ` before it dispatches, so it has to decide first or it
// leaves a dangling keyword behind.
export function classEmitsNoJs(node: Node): boolean {
	if (node.flags.has(NodeFlag.ExternC)) return true;
	return node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.Function;
}

function emitClassDeclInner(gen: JSGenerator, node: Node, assigned: boolean = false): void {
	const d = node.data as ClassDeclData;
	if (classEmitsNoJs(node)) return;
	if (!classEmitsShell(node)) {
		for (const member of d.classBody) {
			if (member.kind == NodeKind.MethodDecl && (member.data as MethodDeclData).methodIsStatic) emitStaticMethodFn(gen, d.className, member);
		}
		return;
	}
	const generic = isGenericClass(node);
	const name = jsSymbolName(gen, node.resolvedSym, d.className);
	declareBinding(gen, name);
	emit(gen, assigned ? `${name} = class ` : "class ");
	emit(gen, name);
	if (d.classExtends != "") {
		emit(gen, " extends ");
		emit(gen, jsBaseClassName(gen, node, d.classExtends));
	}
	emit(gen, " {\n");
	gen.indentLevel = gen.indentLevel + 1;
	if (d.classDisplayName == "") throw new Error(`internal: class '${d.className}' has no source display name`);
	emitIndent(gen);
	emit(gen, `static [globalThis.Symbol.for("metascript.typeDisplayName")] = "${escapeJSString(d.classDisplayName)}";\n`);
	const staticMethods: Node[] = [];
	for (const member of d.classBody) {
		if (generic && !isStaticClassState(member) && !(member.kind == NodeKind.MethodDecl && (member.data as MethodDeclData).methodIsStatic)) continue;
		match (member.kind) {
			NodeKind.MethodDecl => {
				if ((member.data as MethodDeclData).methodIsStatic) { staticMethods.push(member); }
				else if (gen.actorHandle != null && isActorMessage(member)) { emitActorMessageMethod(gen, member); }
				else { emitMethodDecl(gen, member); }
			},
			NodeKind.ConstructorDecl => { emitConstructorDecl(gen, member); },
			NodeKind.PropertyDecl => {
				const pd = member.data as PropertyDeclData;
				if (pd.propIsStatic) {
					emitStaticPropertyDecl(gen, member);
				} else if (gen.actorHandle != null) {
					// Actor instance fields emit as JS class fields, in
					// declaration order, running before any constructor body —
					// the same defaults-then-ctor order as the C runtime.
					emitIndent(gen);
					if (member == gen.actorHandle) {
						// Synthetic registration field (see emitActorDecl).
						// Self-bootstrapping: a program may use actors WITHOUT
						// importing std/actor, so the registrar installs itself
						// on first construction. std/actor's stop() reads the
						// same globalThis registry.
						emit(gen, "pid = (globalThis.__msActorRegister || (globalThis.__msActorRegister = function (a) {\n");
						emitIndent(gen);
						emit(gen, "\tvar g = globalThis.__msActors || (globalThis.__msActors = { next: 1n, live: new Map() });\n");
						emitIndent(gen);
						emit(gen, "\tg.live.set(g.next, a);\n");
						emitIndent(gen);
						emit(gen, "\treturn g.next++;\n");
						emitIndent(gen);
						emit(gen, "}))(this);\n");
					} else if (pd.propInitializer != null) {
						emit(gen, `${safeJsName(pd.propName)} = `);
						emitNode(gen, pd.propInitializer);
						emit(gen, ";\n");
					}
				} else {
					const zero = jsDefaultValue(member.nodeType);
					if (zero != "") {
						emitIndent(gen);
						emit(gen, `${pd.propName} = ${zero};\n`);
					}
				}
			},
			NodeKind.BlockStmt => {
				emitIndent(gen);
				emit(gen, "static ");
				emitBlockInline(gen, member);
				emitNewline(gen);
			},
			_ => { emitNode(gen, member); },
		};
	}
	gen.indentLevel = gen.indentLevel - 1;
	emitIndent(gen);
	emit(gen, assigned ? "};\n" : "}\n");
	if (assigned) return;
	for (const member of staticMethods) {
		emitStaticMethodFn(gen, d.className, member);
	}
}

export function classEvaluatesStatics(node: Node): boolean {
	if (node.kind != NodeKind.ClassDecl || classEmitsNoJs(node) || !classEmitsShell(node)) return false;
	for (const member of (node.data as ClassDeclData).classBody) {
		if (member.kind == NodeKind.BlockStmt) return true;
		if (member.kind == NodeKind.PropertyDecl && (member.data as PropertyDeclData).propIsStatic && (member.data as PropertyDeclData).propInitializer != null) return true;
	}
	return false;
}

export function emitDeferredClassBinding(gen: JSGenerator, node: Node): void {
	const d = node.data as ClassDeclData;
	emitIndent(gen);
	emit(gen, `let ${jsSymbolName(gen, node.resolvedSym, d.className)};\n`);
	for (const member of d.classBody) {
		if (member.kind == NodeKind.MethodDecl && (member.data as MethodDeclData).methodIsStatic) emitStaticMethodFn(gen, d.className, member);
	}
}

export function emitDeferredClassValue(gen: JSGenerator, node: Node): void {
	emitIndent(gen);
	emitClassDeclInner(gen, node, true);
}

function emitStaticMethodFn(gen: JSGenerator, className: string, member: Node): void {
	const d = member.data as MethodDeclData;
	if (isExternFlag(d.methodFlags)) return;
	if (d.methodFlags.indexOf("overload", 0) >= 0) return;
	if (isGenericRoutine(member, d.methodFlags)) return;
	emitIndent(gen);
	const autoAsync = needsAutoAsync(d.methodFlags, d.methodBody);
	match (routineKindFlag(d.methodFlags)) {
		"async" => { emit(gen, "async function "); },
		"generator" => { emit(gen, autoAsync ? "async function* " : "function* "); },
		"async_generator" => { emit(gen, "async function* "); },
		_ => { emit(gen, autoAsync ? "async function " : "function "); },
	};
	const fnEmitted = jsSymbolName(gen, member.resolvedSym, className + "_" + d.methodName);
	declareBinding(gen, fnEmitted);
	emit(gen, fnEmitted);
	emit(gen, "(");
	emitJoinedSafeParams(gen, member, skipThisParams(d.methodParams), ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.methodBody);
	emitNewline(gen);
}

export function emitClassDecl(gen: JSGenerator, node: Node): void {
	if (classEmitsNoJs(node)) return;
	emitIndent(gen);
	emitClassDeclInner(gen, node);
}

// ===== Actor Declaration =====

// Same adapter shape the C backend's actorLower uses to build its state class.
export function emitActorDecl(gen: JSGenerator, node: Node): void {
	if (node.flags.has(NodeFlag.ExternC)) return;
	const d = node.data as ActorDeclData;
	// Tier-1 actor surface: the synthesized class carries a synthetic `pid`
	// field FIRST (before user field defaults — a default may read state, so
	// registration must already have run). The field body is emitted raw by
	// emitClassDeclInner's PropertyDecl arm (globalThis registry — a node-form
	// call would miss the bundle's module-qualified name mangling).
	const pidField = createNodeAt(NodeKind.PropertyDecl, {
		propName: "pid",
		propType: "int64",
		propIsStatic: false,
		propIsReadonly: true,
		propVisibility: "",
		propInitializer: null as unknown as Node,
	} as PropertyDeclData, node.location);
	const body: Node[] = [pidField];
	for (const m of d.actorBody) body.push(m);
	const cls = createNodeAt(NodeKind.ClassDecl, {
		className: d.actorName,
		classDisplayName: d.actorName,
		classExtends: "",
		classBody: body,
		nameLocation: d.nameLocation,
		classImplements: [],
	} as ClassDeclData, node.location);
	cls.resolvedSym = node.resolvedSym;
	gen.actorHandle = pidField;
	emitIndent(gen);
	emitClassDeclInner(gen, cls);
	gen.actorHandle = null;
}

// ===== Method Declaration =====

// Strip leading "this" from param list — JS class methods have implicit this.
function skipThisParams(params: string[]): string[] {
	if (params.length > 0 && params[0] == "this") {
		const result: string[] = [];
		for (let i = 1; i < params.length; i += 1) { result.push(params[i]); }
		return result;
	}
	return params;
}

export function emitMethodDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as MethodDeclData;
	emitMethodDeclNamed(gen, node, jsMethodMemberName(d.methodName, node.resolvedSym));
}

function emitMethodDeclNamed(gen: JSGenerator, node: Node, memberName: string): void {
	const d = node.data as MethodDeclData;
	if (isExternFlag(d.methodFlags)) return;
	if (d.methodFlags.indexOf("overload", 0) >= 0) return;
	if (isGenericRoutine(node, d.methodFlags)) return;
	emitIndent(gen);
	if (d.methodIsStatic) { emit(gen, "static "); }
	const autoAsync = needsAutoAsync(d.methodFlags, d.methodBody);
	match (routineKindFlag(d.methodFlags)) {
		"async" => { emit(gen, "async "); },
		"generator" => { emit(gen, autoAsync ? "async *" : "*"); },
		"async_generator" => { emit(gen, "async *"); },
		_ => { if (autoAsync) emit(gen, "async "); },
	};
	emit(gen, memberName);
	emit(gen, "(");
	emitJoinedSafeParams(gen, node, skipThisParams(d.methodParams), ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.methodBody);
	emitNewline(gen);
}

function isActorMessage(node: Node): boolean {
	const d = node.data as MethodDeclData;
	if (isExternFlag(d.methodFlags) || d.methodFlags.indexOf("overload", 0) >= 0) return false;
	return d.methodName != "onTerminate" && d.methodName != "onExit" && d.methodName != "onDown" && d.methodName != "onIdle";
}

function emitActorMessageMethod(gen: JSGenerator, node: Node): void {
	const d = node.data as MethodDeclData;
	useActorRuntime(gen);
	const memberName = jsMethodMemberName(d.methodName, node.resolvedSym);
	const implName = "$impl_" + memberName;
	emitMethodDeclNamed(gen, node, implName);
	const params = skipThisParams(d.methodParams);
	const isVoid = d.methodReturnType == "" || d.methodReturnType == "void";
	emitIndent(gen);
	emit(gen, memberName);
	emit(gen, "(");
	emitJoinedSafeParams(gen, node, params, ", ", safeJsName);
	emit(gen, isVoid ? ") { msActorRt().send(this, () => this." : ") { return msActorRt().call(this, () => this.");
	emit(gen, implName);
	emit(gen, "(");
	emitJoinedSafeParams(gen, node, params, ", ", safeJsName);
	emit(gen, ")); }\n");
}

// ===== Constructor Declaration =====

export function emitConstructorDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ConstructorDeclData;
	emitIndent(gen);
	emit(gen, "constructor(");
	emitJoinedSafeParams(gen, node, d.ctorParams, ", ", safeJsName);
	emit(gen, ") ");
	emitBodyOrEmpty(gen, d.ctorBody);
	emitNewline(gen);
}

// ===== Import Declaration =====

export function emitImportDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ImportDeclData;
	// .h imports have no JavaScript counterpart — their extern decls are
	// inlined alongside the ImportDecl by inlineHeaderImports, and the JS
	// backend doesn't consume C headers. Skip emission entirely.
	if (d.importSource.length >= 2 && d.importSource.slice(d.importSource.length - 2, d.importSource.length) == ".h") return;
	// std/meta is the compile-time AST/macro API — no runtime JS counterpart.
	if (d.importSource == "std/meta" || (d.importSource.length >= 9 && d.importSource.slice(0, 9) == "std/meta/")) return;
	// Bundle: every module shares one flat scope and names carry module
	// identity, so cross-module references need no binding statement.
	if (gen.bundleMode) return;
	// Multi-file: named bindings are derived from actual references
	// (recordNeededImport), so the source import contributes only module
	// evaluation order — a bare side-effect import.
	if (gen.multiFile) {
		const spec = lookupImportSpec(gen, d.importSource);
		if (spec == "") return;
		if (d.importNames.length == 1 && d.importNames[0] == "*") {
			gen.moduleRequests = gen.moduleRequests + `import * as ${d.importAliases[0]} from "${spec}";\n`;
		} else {
			gen.moduleRequests = gen.moduleRequests + `import "${spec}";\n`;
		}
		return;
	}
	// Non-bundle mode: ES module import
	emitIndent(gen);
	if (d.importNames.length == 0) {
		emit(gen, "import \"");
		emit(gen, convertImportPath(d.importSource));
		emit(gen, "\";\n");
		return;
	}
	// Namespace import: import * as ns from "path"
	if (d.importNames.length == 1 && d.importNames[0] == "*") {
		emit(gen, "import * as ");
		emit(gen, d.importAliases[0]);
		emit(gen, " from \"");
		emit(gen, convertImportPath(d.importSource));
		emit(gen, "\";\n");
		return;
	}
	emit(gen, "import { ");
	for (let i = 0; i < d.importNames.length; i += 1) {
		if (i > 0) emit(gen, ", ");
		emit(gen, d.importNames[i]);
		if (i < d.importAliases.length && d.importAliases[i] != "" && d.importAliases[i] != d.importNames[i]) {
			emit(gen, " as ");
			emit(gen, d.importAliases[i]);
		}
	}
	emit(gen, " } from \"");
	emit(gen, convertImportPath(d.importSource));
	emit(gen, "\";\n");
}

// ===== Export Declaration =====

function recordBundleExport(gen: JSGenerator, name: string, local: string): void {
	gen.exportedNames.push(name);
	gen.bundleExportLocals.push(local);
}

function bundleDefaultLocal(gen: JSGenerator): string {
	return mangleQualified("default", mangleModuleName(gen.sourceFile));
}

function emitBundleDefaultExport(gen: JSGenerator, exprStmt: Node, declaration: string): void {
	const local = bundleDefaultLocal(gen);
	emitIndent(gen);
	emit(gen, `${declaration}${local} = `);
	emitCopyOnRead(gen, (exprStmt.data as ExprStmtData).expr);
	emit(gen, ";\n");
	recordBundleExport(gen, "default", local);
}

export function emitDeferredDefaultExport(gen: JSGenerator, node: Node): void {
	gen.staticSlots.push(`let ${bundleDefaultLocal(gen)};\n`);
	emitBundleDefaultExport(gen, (node.data as ExportDeclData).exportedDecl, "");
}

export function emitExportDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as ExportDeclData;
	const inner = d.exportedDecl;
	// Star re-export: export * from "path"
	if (inner.kind == NodeKind.ImportDecl) {
		const imp = inner.data as ImportDeclData;
		// Multi-file: every re-export form emits as `export * from` — a named
		// list can mix runtime values with types, and naming a type binding
		// that has no JS emission is a load-time error. Star matches at
		// runtime, so type names simply don't participate. MS-compiled
		// consumers resolve through the registry straight to the origin
		// module anyway; the hub's surface only matters to hand-written JS.
		if (gen.multiFile) {
			const spec = lookupImportSpec(gen, imp.importSource);
			if (spec == "") return;
			gen.moduleRequests = gen.moduleRequests + `export * from "${spec}";\n`;
			return;
		}
		if (imp.importNames.length == 1 && imp.importNames[0] == "*") {
			if (!gen.bundleMode) {
				emitIndent(gen);
				emit(gen, "export * from \"");
				emit(gen, convertImportPath(imp.importSource));
				emit(gen, "\";\n");
			}
			return;
		}
	}
	// Skip type-only exports (no JS output)
	if (inner.kind == NodeKind.InterfaceDecl) return;
	if (inner.kind == NodeKind.StructDecl) return;
	if (inner.kind == NodeKind.TypeAliasDecl) return;
	if (inner.kind == NodeKind.ExternDecl) return;
	// Compile-time-only — no runtime JS (mirrors the bare-decl skip in jsgen.ms)
	if (inner.kind == NodeKind.MacroDecl) return;
	if (inner.kind == NodeKind.ComptimeBlock) return;
	if (inner.kind == NodeKind.FunctionDecl && !emittableFunctionDecl(inner)) return;
	if (inner.kind == NodeKind.ClassDecl && !classEmitsShell(inner)) { emitClassDecl(gen, inner); return; }
	const isDefault = node.flags.has(NodeFlag.ExportDefault);
	if (gen.bundleMode) {
		if (isDefault && inner.kind == NodeKind.ExprStmt) {
			emitBundleDefaultExport(gen, inner, "const ");
			return;
		}
		let declName = "";
		if (inner.kind == NodeKind.FunctionDecl && !isExtensionRoutine((inner.data as FunctionDeclData).fnFlags)) { declName = (inner.data as FunctionDeclData).fnName; }
		else if (inner.kind == NodeKind.VariableDecl) { declName = (inner.data as VariableDeclData).declName; }
		else if (inner.kind == NodeKind.ClassDecl) { declName = (inner.data as ClassDeclData).className; }
		const before = gen.buf.length;
		emitNode(gen, inner);
		if (declName != "" && gen.buf.length > before) recordBundleExport(gen, isDefault ? "default" : declName, jsSymbolName(gen, inner.resolvedSym, declName));
		return;
	}
	// Non-bundle: ES module export
	if (inner.kind == NodeKind.ClassDecl && classEmitsNoJs(inner)) return;
	if (inner.kind == NodeKind.ActorDecl && inner.flags.has(NodeFlag.ExternC)) return;
	emitIndent(gen);
	emit(gen, isDefault ? "export default " : "export ");
	if (isDefault && inner.kind == NodeKind.ExprStmt) {
		emitCopyOnRead(gen, (inner.data as ExprStmtData).expr);
		emit(gen, ";\n");
		return;
	}
	match (inner.kind) {
		NodeKind.FunctionDecl => {
			if (gen.multiFile) { gen.exportedNames.push(jsSymbolName(gen, inner.resolvedSym, (inner.data as FunctionDeclData).fnName)); }
			emitFunctionDeclInner(gen, inner);
		},
		NodeKind.VariableDecl => {
			const vd = inner.data as VariableDeclData;
			match (vd.declKind) {
				DeclKind.Const => { emit(gen, "const "); },
				DeclKind.Var => { emit(gen, "var "); },
				_ => { emit(gen, "let "); },
			};
			if (gen.multiFile) { gen.exportedNames.push(safeJsName(vd.declName)); }
			emit(gen, safeJsName(vd.declName));
			if (vd.initializer != null) {
				emit(gen, " = ");
				emitNode(gen, vd.initializer);
			}
			emit(gen, ";\n");
		},
		NodeKind.EnumDecl => {
			const ed = inner.data as EnumDeclData;
			if (gen.multiFile) {
				for (const m of ed.enumMembers) { gen.exportedNames.push(enumMemberName(inner.resolvedSym, safeJsName(ed.enumName), m)); }
			}
			emitEnumDeclInner(gen, inner, gen.multiFile ? "export " : "");
			if (gen.multiFile) {
				gen.exportedNames.push(safeJsName(ed.enumName));
				emitIndent(gen);
				emit(gen, `export ${jsEnumObject(safeJsName(ed.enumName), ed)}`);
			}
		},
		NodeKind.ClassDecl => {
			if (gen.multiFile) { gen.exportedNames.push(jsSymbolName(gen, inner.resolvedSym, (inner.data as ClassDeclData).className)); }
			emitClassDeclInner(gen, inner);
		},
		NodeKind.ActorDecl => {
			if (gen.multiFile) { gen.exportedNames.push(jsSymbolName(gen, inner.resolvedSym, (inner.data as ActorDeclData).actorName)); }
			emitActorDecl(gen, inner);
		},
		_ => { emitNode(gen, inner); },
	};
}

// ===== Decorated Declaration =====

export function emitDecoratedDecl(gen: JSGenerator, node: Node): void {
	const d = node.data as DecoratedDeclData;
	// Skip decorators, just emit the inner declaration
	emitNode(gen, d.decoratedNode);
}
