import { Node, NodeKind, NodeFlag, ProgramData, FunctionDeclData, BlockStmtData, IdentifierData, MemberExprData, ObjectLiteralData, createNode, SourceLocation, SymbolKind, Type, TypeKind } from "../../ast/node";
import { exportedFunctionOf } from "../../checker/decoratorHelpers";
import { hasGenericParams, createPtr, createStruct, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { mangledFunctionName, mangledGlobalName, isModuleGlobalVar, referenceName, mangleModuleName, safeName } from "../../codegen/c/names";
import { isNrvoReturnType, opCName } from "../../codegen/c/types";
import { hcrSignatureKey } from "../../compiler/hcrAbi";
import { walkNode } from "../walker";
import { syntheticToken, makeHiddenDeref, makeTypedIdent, makeMember, makeCall, runtimeRef } from "../util";
import { AliveSet, CEmissionFacts } from "../../codegen/c/context";
import { functionDeclIsAlive } from "../../checker/reachability";
import { hcrStorageDecl } from "./hcrLift";

export struct HcrIndirectModule {
	moduleId: string;
	modulePath: string;
	typeInfos: string[];
	typeKeys: string[];
	imports: string[];
	beforeReload: string[];
	afterReload: string[];
}

export struct HcrFunction {
	symbol: string;
	key: string;
	sourcePath: string;
	forwards: boolean;
}

export function hcrFunctions(program: Node, aliveSet: Readonly<AliveSet>, modulePath: string, facts: Readonly<CEmissionFacts>): HcrFunction[] {
	const functions: HcrFunction[] = [];
	const seen = new HashSet<string>();
	for (const stmt of (program.data as ProgramData).programStmts) {
		const fn = exportedFunctionOf(stmt);
		if (fn == null || !functionDeclIsAlive(aliveSet, modulePath, fn)) continue;
		const d = fn.data as FunctionDeclData;
		const sym = fn.resolvedSym;
		if (d.fnBody == null || d.fnFlags.indexOf("extern", 0) >= 0 || fn.nodeType == null || hasGenericParams(fn.nodeType)) continue;
		if (sym != null && (hasFlag(sym, SymbolFlag.ImportC) || hasFlag(sym, SymbolFlag.OverloadSig))) continue;
		const symbol = mangledFunctionName(sym, d.fnName, sym != null ? sym.overloadIdx : 0);
		if (facts.genericOwners.has(symbol) && facts.genericOwners.readonlyGet(symbol) != modulePath) continue;
		if (seen.has(symbol)) continue;
		seen.add(symbol);
		functions.push({
			symbol,
			key: "f:" + hcrSignatureKey(sym != null ? sym.symbolType : fn.nodeType),
			sourcePath: sym != null ? sym.modulePath : "",
			forwards: sym != null && !d.fnName.startsWith("$"),
		});
	}
	for (const stmt of (program.data as ProgramData).programStmts) {
		const op = stmt.kind == NodeKind.FunctionDecl ? stmt.resolvedSym : null;
		if (op == null || !aliveSet.foreignOps.has(op)) continue;
		const symbol = opCName(op);
		if (seen.has(symbol)) continue;
		seen.add(symbol);
		functions.push({
			symbol,
			key: "f:" + hcrSignatureKey(op.symbolType != null ? op.symbolType : stmt.nodeType),
			sourcePath: modulePath,
			forwards: !(stmt.data as FunctionDeclData).fnName.startsWith("$"),
		});
	}
	return functions;
}

function moduleForPath(modules: HcrIndirectModule[], path: string): HcrIndirectModule | null {
	for (const module of modules) if (module.modulePath == path) return module;
	return null;
}

export function lowerHcrIndirection(
	program: Node,
	own: HcrIndirectModule,
	modules: HcrIndirectModule[],
	owners: HashMap<string, string>,
	aliveSet: Readonly<AliveSet>,
	facts: Readonly<CEmissionFacts>,
): Node {
	if (program == null || program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const loc = program.location;
	const functions = hcrFunctions(program, aliveSet, own.modulePath, facts);
	const ownFunctions = new HashSet<string>();
	for (const fn of functions) ownFunctions.add(fn.symbol);
	const emitted: Node[] = [makeEmitStmt("/*INCLUDESECTION*/#include \"runtime/hcr.h\"", loc)];
	const registrations: Node[] = [];
	const selfCells = new HashMap<string, string>();
	const entries = new HashMap<string, string>();
	let selfSlot: int32 = 0;
	let published = "";
	for (const fn of functions) {
		published = published + `${cString(fn.symbol)}, ${cString(fn.key)}, `;
		const register = `msHcrRegisterFunction(${cString(own.moduleId)}, ${cString(fn.symbol)}, ${cString(fn.key)}, (void*)&${fn.symbol}, ${fn.forwards ? 1 : 0})`;
		if (!fn.forwards) {
			registrations.push(makeEmitStmt(`/*DATINITSECTION*/  ${register};`, loc));
			continue;
		}
		const cell = `_ms_hcr_self_${mangleModuleName(own.modulePath)}_${selfSlot}`;
		selfSlot += 1;
		selfCells.set(fn.symbol, cell);
		emitted.push(makeEmitStmt(`/*VARSECTION*/static MsHcrCell* ${cell};`, loc));
		registrations.push(makeEmitStmt(`/*DATINITSECTION*/  ${cell} = ${register};`, loc));
	}
	emitted.push(makeEmitStmt(`MS_HCR_EXPORT const char* HcrModuleId000(void) { return ${cString(own.moduleId)}; }`, loc));
	emitted.push(makeEmitStmt(`MS_HCR_EXPORT const char* const* HcrFunctions000(void) { static const char* const symbols[] = { ${published}NULL }; return symbols; }`, loc));
	let imports = "";
	for (const id of own.imports) imports = imports + cString(id) + ", ";
	emitted.push(makeEmitStmt(`MS_HCR_EXPORT const char* const* HcrImports000(void) { static const char* const imports[] = { ${imports}NULL }; return imports; }`, loc));
	emitted.push(makeEmitStmt(typeKeysFunction(own), loc));
	if (own.beforeReload.length > 0) emitted.push(makeEmitStmt(handlerFunction("HcrBeforeReload000", own.beforeReload), loc));
	if (own.afterReload.length > 0) emitted.push(makeEmitStmt(handlerFunction("HcrAfterReload000", own.afterReload), loc));

	const bound = new HashMap<string, string>();
	const storageTypes = new HashMap<string, Type>();
	let bindings = "";
	let bindSlot: int32 = 0;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const fn = exportedFunctionOf(pd.programStmts[i]);
		if (fn != null) {
			const sym = fn.resolvedSym;
			const data = fn.data as FunctionDeclData;
			const symbol = mangledFunctionName(sym, data.fnName, sym != null ? sym.overloadIdx : 0);
			if (!ownFunctions.has(symbol)) continue;
			const cell = selfCells.get(symbol);
			if (cell != null) forwardToCurrent(fn, symbol, cell);
		}
		pd.programStmts[i] = walkNode(pd.programStmts[i], (n: Node): Node => {
			if (n.kind == NodeKind.ObjectLiteral) {
				const target = closureFunction(n);
				if (target == null) return n;
				const sym = target.resolvedSym;
				const symbol = mangledFunctionName(sym, referenceName(sym, referenceText(target)), sym.overloadIdx);
				let cell = selfCells.get(symbol);
				if (cell == null) {
					const owner = owners.get(symbol);
					if (owner == null || owner == own.moduleId) return n;
					cell = bound.get(owner + "\n" + symbol + "\nf:" + hcrSignatureKey(sym.symbolType));
					if (cell == null) throw new Error(`internal: '${owner}::${symbol}' taken as a value without an HCR binding`);
				}
				const value = `${cell}_value`;
				if (!entries.has(cell)) {
					entries.set(cell, value);
					emitted.push(makeEmitStmt(`/*VARSECTION*/#define ${value} (msHcrFunctionValue(${cell}))`, loc));
				}
				(n.data as ObjectLiteralData).properties[0] = makeTypedIdent(value, target.nodeType, target.location);
				return n;
			}
			if (n.kind != NodeKind.Identifier && n.kind != NodeKind.MemberExpr) return n;
			const sym = n.resolvedSym;
			if (sym == null) return n;
			if (n.kind == NodeKind.MemberExpr) {
				const baseSym = (n.data as MemberExprData).object.resolvedSym;
				if (baseSym == null || baseSym.symbolKind != SymbolKind.Module) return n;
			}
			const isVariable = isModuleGlobalVar(sym);
			const text = referenceText(n);
			const symbol = isVariable
				? mangledGlobalName(sym, referenceName(sym, text))
				: mangledFunctionName(sym, referenceName(sym, text), sym.overloadIdx);
			let targetId = "";
			if (isVariable) {
				const target = moduleForPath(modules, sym.modulePath);
				if (target == null || target.moduleId == own.moduleId) return n;
				targetId = target.moduleId;
			} else {
				if (sym.symbolKind != SymbolKind.Function || ownFunctions.has(symbol)) return n;
				const owner = owners.get(symbol);
				if (owner == null || owner == own.moduleId) return n;
				targetId = owner;
			}
			const key = (isVariable ? "v:" : "f:") + hcrSignatureKey(sym.symbolType);
			const id = targetId + "\n" + symbol + "\n" + key;
			const cachedPointer = bound.get(id);
			const pointer = cachedPointer != null ? cachedPointer : `_ms_hcr_bind_${mangleModuleName(own.modulePath)}_${bindSlot}`;
			if (cachedPointer == null) {
				bindSlot += 1;
				bound.set(id, pointer);
				bindings = bindings + `${cString(targetId)}, ${cString(symbol)}, ${cString(key)}, `;
				if (isVariable) {
					const storageType = createStruct(`_ms_hcr_import_value${bindSlot}`, ["value"], [sym.symbolType], true);
					storageTypes.set(id, storageType);
					emitted.push(hcrStorageDecl(storageType, loc));
					emitted.push(makeEmitStmt(`/*VARSECTION*/static MsHcrCell* ${pointer};`, loc));
					emitted.push(makeEmitStmt(
						`/*DATINITSECTION*/  ${pointer} = msHcrBind(${cString(targetId)}, ${cString(symbol)}, ${cString(key)});`,
						loc,
					));
				} else {
					emitted.push(makeEmitStmt(`/*VARSECTION*/static MsHcrCell* ${pointer};`, loc));
					emitted.push(makeEmitStmt(
						`/*DATINITSECTION*/  ${pointer} = msHcrBind(${cString(targetId)}, ${cString(symbol)}, ${cString(key)});`,
						loc,
					));
					emitted.push(makeEmitStmt(`/*VARSECTION*/#define ${symbol} ((__typeof__(&${symbol}))${pointer}->current)`, loc));
				}
			}
			if (!isVariable) return n;
			const storageType = storageTypes.get(id);
			if (storageType == null) throw new Error(`internal: missing HCR storage type for '${targetId}::${symbol}'`);
			const raw = makeCall(runtimeRef("msHcrVariableStorage", n.location), [makeTypedIdent(pointer, createPtr(voidType()), n.location)], n.location);
			raw.nodeType = createPtr(voidType());
			const cast = createNode(NodeKind.TypeAssertion, { asExpr: raw, asType: storageType.typeName }, syntheticToken(n.location));
			cast.nodeType = createPtr(storageType);
			const value = makeMember(makeHiddenDeref(cast, n.location), "value", n.location);
			value.nodeType = n.nodeType != null ? n.nodeType : sym.symbolType;
			return value;
		});
	}
	emitted.push(makeEmitStmt(`MS_HCR_EXPORT const char* const* HcrBindings000(void) { static const char* const bindings[] = { ${bindings}NULL }; return bindings; }`, loc));
	for (const stmt of pd.programStmts) emitted.push(stmt);
	for (const stmt of registrations) emitted.push(stmt);
	pd.programStmts = emitted;
	return program;
}

function referenceText(n: Node): string {
	return n.kind == NodeKind.Identifier ? (n.data as IdentifierData).name : (n.data as MemberExprData).property;
}

function closureFunction(n: Node): Node | null {
	if (!n.flags.has(NodeFlag.Closure)) return null;
	const values = (n.data as ObjectLiteralData).properties;
	if (values.length != 2 || values[1].kind != NodeKind.NullLiteral) return null;
	const target = values[0];
	const sym = target.resolvedSym;
	if (sym == null || sym.symbolKind != SymbolKind.Function) return null;
	if (target.kind == NodeKind.Identifier) return target;
	if (target.kind != NodeKind.MemberExpr) return null;
	const baseSym = (target.data as MemberExprData).object.resolvedSym;
	return baseSym != null && baseSym.symbolKind == SymbolKind.Module ? target : null;
}

function forwardToCurrent(fn: Node, symbol: string, cell: string): void {
	const d = fn.data as FunctionDeclData;
	const fnType = fn.nodeType;
	if (d.fnBody == null || d.fnBody.kind != NodeKind.BlockStmt || fnType == null || fnType.kind != TypeKind.Function) {
		throw new Error(`internal: HCR function '${symbol}' has no body or function type to forward from`);
	}
	const nrvo = isNrvoReturnType(fnType.typeReturn, fnType);
	const args: string[] = nrvo ? ["__result"] : [];
	for (const param of d.params) args.push(safeName(param));
	const call = `((__typeof__(&${symbol}))${cell}->current)(${args.join(", ")})`;
	const returnsValue = !nrvo && fnType.typeReturn != null && fnType.typeReturn.kind != TypeKind.Void;
	const forward = returnsValue ? `return ${call};` : `{ ${call}; return; }`;
	const block = d.fnBody.data as BlockStmtData;
	const statements: Node[] = [makeEmitStmt(`if (msHcrMoved(${cell}, (void*)&${symbol})) ${forward}`, fn.location)];
	for (const stmt of block.statements) statements.push(stmt);
	block.statements = statements;
}

function handlerFunction(entry: string, handlers: string[]): string {
	let prototypes = "";
	let calls = "";
	for (const handler of handlers) {
		prototypes = prototypes + `MS_HCR_EXPORT void ${handler}(void); `;
		calls = calls + `${handler}(); if (msErrTake()) return 1; `;
	}
	return `${prototypes}MS_HCR_EXPORT int32_t ${entry}(void) { ${calls}return 0; }`;
}

function typeKeysFunction(own: HcrIndirectModule): string {
	let entries = "";
	for (const entry of own.typeKeys) entries = entries + `${cString(entry)}, `;
	return `MS_HCR_EXPORT const char* const* HcrTypeKeys000(void) { static const char* const keys[] = { ${entries}NULL }; return keys; }`;
}

function cString(value: string): string {
	let out = "\"";
	for (let i = 0; i < value.length; i += 1) {
		const ch = value.charAt(i);
		if (ch == "\\" || ch == "\"") out = out + "\\";
		out = out + ch;
	}
	return out + "\"";
}

function makeEmitStmt(code: string, loc: SourceLocation): Node {
	const strNode = createNode(NodeKind.StringLiteral, { value: code }, syntheticToken(loc));
	const macroNode = createNode(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [strNode], macroHasParens: true }, syntheticToken(loc));
	return createNode(NodeKind.ExprStmt, { expr: macroNode }, syntheticToken(loc));
}
