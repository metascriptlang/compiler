// Prelude Pack — disk cache for buildPreludeContext's result (BUILD-PERF §6, Phase A1)
//
// The prelude block re-reads, re-translates and re-checks the same ~45 std
// modules in EVERY msc process (~150-250 ms after A0). This pack persists the
// checked symbol table so a warm build starts from the finished scope:
//
//   toolStamp = content hash of the msc binary
//   stdTreeHash = content hash of the whole std/ tree (covers sub-modules and
//               per-backend variants — over-invalidation on unused files is
//               accepted for v1)
//
// v2 (2026-09-02): the pack is a SELF-CONTAINED closure — symbols, types AND
// the AST (declNode/defaultParams/macro bodies) serialize together in ONE
// index-linked object graph, exactly like the reference models do it:
// per-module typed-AST serialization with sym defs incl. routine bodies, and
// rustc rmeta (interface artifact + encoded bodies in one metadata blob).
// v1's mistake — serialize interfaces only, then patch AST in from a live
// donor context — broke on every object-identity edge (separate registry
// syms, same-name extensions across receivers, donor registries deduping
// back onto the pack objects). v2 never reaches outside the pack: Node rows
// reference Sym/Type/Node rows by index, the reader materializes the whole
// graph eagerly, and object identity falls out of "one row = one object".

import { Symbol, SymbolFlag, NodeFlag, SymbolKind, SymbolState, Type, TypeKind, Node, NodeData, NodeKind, makeLoc, createNodeAt, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData, FunctionExprData, TypeAssertionData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, HiddenStdConvData, ExprStmtData, TypeAnnotationData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, DestructuringDeclData, VariableDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, BlockStmtData, ReturnStmtData, FunctionDeclData, DoWhileStmtData, SwitchStmtData, SwitchCaseData, MatchStmtData, ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData, ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData, ThrowStmtData, TryCatchStmtData, MacroInvocationData, DecoratedDeclData, DeferStmtData, TestDeclData, AssertStmtData, ExternDeclData, MacroDeclData, QuoteExprData, ComptimeBlockData, TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData, ProgramData, ActorDeclData, SpliceManyData, JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData, NumberLiteralData, StringLiteralData, BooleanLiteralData, BigIntLiteralData, RegexLiteralData, IdentifierData, BreakStmtData, ContinueStmtData, UnreachableStmtData } from "../ast/node";
import { pkSamples, pkDumpNode } from "../ast/fieldspec";
import { DispatchRegistry, createDispatchRegistry } from "./dispatchRegistry";
import { CheckerContext, createContextWithCache, createExtensionRegistry, createExtMethod, registerExtension, DispatchRecords, replayDispatchRecords, extensionsOf } from "./context";
import { CtorRow, replayCtorRoutines, startCtorCapture, endCtorCapture } from "./ctorRoutine";
import { createIdentCache, getIdentId, identName } from "./idents";
import { emptyType, noneType, createGenericParam, createKeyOfType, replayDuVariants } from "./types";
import { makeSymbolState, setFlag, hasFlag } from "./symbol";
import {
	escapeP,
	unescapeP,
	joinCsv,
	splitCsv,
	intsCsv,
	PackReader,
	fieldEnd,
	startRow,
	endRow,
	int,
	str,
	ints,
	RowWriter,
	enqSym,
	enqType,
	closeOver,
	emitObjectRows,
	idxSym,
	idxType,
	RowReader,
	readObjectRow,
	linkTypesAndSymbols,
	linkNodes,
} from "./rowCodec";
import { resolveRuntimeDir, resolveArgv0 } from "../utils/path";
import { globalCacheRoot } from "../utils/cachePaths";
import { getParserDefines, setParserDefines } from "../parser/context";
import { defineIdentity, createDefineTable, defineSymbol } from "../compiler/defines";
import { defaultGlobalImports, setExtraGlobalImports } from "./prelude";
import { readFile, writeFile, exists, remove, removeAll, ensureDir, rename } from "std/fs";
import { env, argv } from "std/process";
import { collectStaleEntries, markUsed, nowSeconds } from "../utils/stampDirs";
import { hashContent, collectFilesSorted } from "../utils/contentHash";

const PACK_MAGIC = "MSPK13";

function hashFile(path: string): string {
	const src = try readFile(path) catch "";
	return hashContent(src);
}

function stampTreePack(acc: string, dir: string, prefix: string): string {
	if (!exists(dir)) return acc;
	const files: string[] = [];
	collectFilesSorted(dir, "", files);
	for (const f of files) {
		acc = `${acc}\n${prefix}${f}:${hashFile(join(dir, f))}`;
	}
	return acc;
}

function join(a: string, b: string): string {
	return a + "/" + b;
}

let _toolStamp = "";
let _toolStampFn: (() => string) | null = null;
let _stdStampFn: ((stdPath: string) => string) | null = null;

// compile.ms registers compiler/cache.compilerStamp and stdTreeStamp at load (memoized
// there, shared with the object cache). Without registration (standalone tests) a local
// equivalent is computed.
export function registerPreludeStampFn(fn: () => string, stdFn: (stdPath: string) => string): void {
	_toolStampFn = fn;
	_stdStampFn = stdFn;
}

function toolStamp(): string {
	if (_toolStamp != "") return _toolStamp;
	if (_toolStampFn != null) {
		_toolStamp = _toolStampFn();
		return _toolStamp;
	}
	_toolStamp = hashFile(resolveArgv0(argv[0]));
	return _toolStamp;
}

let _stdTreeHash = "";
let _stdTreeHashPath = "";
function stdTreeHash(stdPath: string): string {
	if (_stdTreeHash != "" && _stdTreeHashPath == stdPath) return _stdTreeHash;
	if (_stdStampFn != null) {
		_stdTreeHash = _stdStampFn(stdPath);
		_stdTreeHashPath = stdPath;
		return _stdTreeHash;
	}
	let acc = "";
	if (stdPath != "") acc = stampTreePack("", stdPath, "std/");
	_stdTreeHash = hashContent(acc);
	_stdTreeHashPath = stdPath;
	return _stdTreeHash;
}

export function preludePackKey(stdPath: string, backendExt: string): string {
	const _k0 = performance.now();
	const k = hashContent(`${stdPath}|${backendExt}|${defaultGlobalImports().join("|")}|${defineIdentity(getParserDefines())}|${toolStamp()}`);
	_keyMs = _keyMs + (performance.now() - _k0);
	return k;
}

export function preludePackStamp(stdPath: string): string {
	const _k0 = performance.now();
	const s = `${toolStamp()}:${stdTreeHash(stdPath)}`;
	_keyMs = _keyMs + (performance.now() - _k0);
	return s;
}

// Per-process cost breakdown for the -t PROFILE line (build-perf §8).
let _keyMs: float64 = 0;
let _loadMs: float64 = 0;
let _writeMs: float64 = 0;
let _lastHit = false;
export function preludePackStats(): float64[] {
	return [_keyMs, _loadMs, _writeMs, _lastHit ? 1 : 0];
}

function packBase(): string {
	const root = globalCacheRoot();
	return root == "" ? "" : `${root}/prelude`;
}

// One directory per pack format: compilers that read different formats keep their packs side
// by side and none deletes another's. Within a format the stamp inside each pack separates
// compiler builds, and a foreign stamp is a miss, never a deletion.
export function packRoot(): string {
	const base = packBase();
	if (base == "") return "";
	return `${base}/${PACK_MAGIC}`;
}

// Default ON (verified: unit 644, suite 3531/3531, corpus parity 814/0/0, SAN
// 167/0/0 with the pack hot, and emitted-C ON≡OFF by fingerprint reuse).
// MSC_NO_PRELUDE_PACK=1 hard-disables; MSC_NO_GLOBAL_CACHE=1 or unknown HOME
// disables the global cache entirely (pack included).
function packDisabled(): boolean {
	if (env.get("MSC_NO_PRELUDE_PACK") != "") return true;
	return packRoot() == "";
}

function atomicWritePack(path: string, content: string): boolean {
	const tmp = `${path}.tmp.${performance.now()}`;
	if (!writeFile(tmp, content).ok) {
		ensureDir(path.slice(0, path.lastIndexOf("/")));
		if (!writeFile(tmp, content).ok) return false;
	}
	const r = rename(tmp, path);
	if (r.ok) return true;
	remove(tmp);
	return false;
}

// ===== Std-Graph Deps (BUILD-PERF Phase A2) =====
//
// The loader half of the pack family: <key>.deps records the std module
// graph that loadPreludeModules (compile.ms) produced — modules in
// loadOrder order, their resolved import entries, circular-dep records —
// so a warm build seeds the graph directly and skips the lex+parse+resolver
// probe of the ~45 std modules. Same key/root/marker-GC/kill-switches as
// the .pk closure; this is pure DISCOVERY data (no symbols, no AST), so
// none of the v1 identity traps apply.
//
// Rows (tab-separated, same escaping as the .pk):
//   G \t path                                                     module; G-row order IS loadOrder
//   I \t sourcePath \t sourceSpecifier \t namesCsv \t aliasesCsv   import of the last G row
//   R \t fromPath \t toPath \t cycleCsv \t importLine \t importNamesCsv

export interface DepsImportRow {
	names: string[];
	aliases: string[];
	sourcePath: string;
	sourceSpecifier: string;
}

export interface DepsModuleRow {
	path: string;
	imports: DepsImportRow[];
}

export interface DepsCircularRow {
	fromPath: string;
	toPath: string;
	cycle: string[];
	importLine: int32;
	importNames: string[];
}

export interface PreludeDepsSnapshot {
	mods: DepsModuleRow[];
	circulars: DepsCircularRow[];
}

export function writePreludeDeps(key: string, stamp: string, snap: PreludeDepsSnapshot): void {
	if (packDisabled()) return;
	const root = packRoot();
	ensureDir(root);
	const lines: string[] = [`K\t${key}\t${stamp}`];
	for (const m of snap.mods) {
		lines.push(`G\t${escapeP(m.path)}`);
		for (const imp of m.imports) {
			lines.push(`I\t${escapeP(imp.sourcePath)}\t${escapeP(imp.sourceSpecifier)}\t${joinCsv(imp.names)}\t${joinCsv(imp.aliases)}`);
		}
	}
	for (const c of snap.circulars) {
		lines.push(`R\t${escapeP(c.fromPath)}\t${escapeP(c.toPath)}\t${joinCsv(c.cycle)}\t${c.importLine}\t${joinCsv(c.importNames)}`);
	}
	atomicWritePack(`${root}/${key}.deps`, lines.join("\n"));
}

// What a prelude check registers in the per-build tables beside its context.
export interface PreludeTables {
	duVariants: Type[];
	ctorRoutines: CtorRow[];
	dispatch: DispatchRecords;
}

export function emptyPreludeTables(): PreludeTables {
	return { duVariants: [], ctorRoutines: [], dispatch: { classSyms: [], methodNames: [], methodSyms: [] } };
}

export function replayPreludeTables(tables: PreludeTables, dispatchRegistry: DispatchRegistry): void {
	replayDuVariants(tables.duVariants);
	replayCtorRoutines(tables.ctorRoutines);
	replayDispatchRecords(dispatchRegistry, tables.dispatch);
}

// ===== Writer =====
//
// Line format (tab-separated; \1.. prefixes keep the reader dumb):
//   T, N, S object rows: rowCodec.ms
//   E methodName sourcePath isStatic scopeDepth symIdx
//   C converterSymIdx targetTypeIdx
//   P compilerFuncName symIdx
//   D includeDirectives
//   F compilerFlags
//   X compileDirectives
//   Q duVariantTypesCsv
//   R classSymIdx methodName methodSymIdx
//   A ownerSymIdx routineSymIdx

export function writePreludePack(key: string, stamp: string, ctx: CheckerContext, tables: PreludeTables): void {
	const _w0 = performance.now();
	if (packDisabled()) return;
	const root = packRoot();
	ensureDir(root);

	const w = new RowWriter();
	for (const s of ctx.table.current.symbols.values()) {
		w.enqSym(s, true);
	}
	// Extension methods can reference Symbol objects that are NOT the scope
	// symbols (registry entries hold their own sym identity — e.g. a specific
	// overload) — walk them into the closure or the pack emits ext.sym=null
	// and every extension call fails to match on load. Same for converter
	// payload types.
	if (ctx.extensionRegistry != null) {
		for (const ext of extensionsOf(ctx.extensionRegistry)) {
			w.enqSym(ext.sym, false);
		}
	}
	for (const conv of ctx.converterTargetTypes.keys()) {
		w.enqSym(conv, false);
	}
	for (const ct of ctx.converterTargetTypes.values()) {
		w.enqType(ct);
	}
	for (const members of ctx.preludeInterf.values()) {
		for (const m of members) w.enqSym(m, false);
	}
	for (const members of ctx.preludeModuleScopes.values()) {
		for (const m of members) w.enqSym(m, false);
	}
	for (const v of tables.duVariants) w.enqType(v);
	for (let i = 0; i < tables.dispatch.methodSyms.length; i += 1) {
		w.enqSym(tables.dispatch.classSyms[i], false);
		w.enqSym(tables.dispatch.methodSyms[i], false);
	}
	for (const row of tables.ctorRoutines) {
		w.enqSym(row.owner, false);
		w.enqSym(row.routine, false);
	}
	w.closeOver();

	const packDebug = env.get("MSC_PACK_DEBUG") != "";
	if (packDebug) console.log(`[pack] closure syms=${w.syms.length} types=${w.types.length} nodes=${w.nodes.length} ms=${performance.now() - _w0}`);

	const lines: string[] = [];
	lines.push(PACK_MAGIC);
	lines.push(`V\t${stamp}`);
	w.emitObjectRows(lines);

	const importIdx: int32[] = [];
	const interfIdx: int32[] = [];
	for (let i = 0; i < w.syms.length; i += 1) {
		if (ctx.importSet.has(w.syms[i])) importIdx.push(i as int32);
		if (ctx.interfSet.has(w.syms[i])) interfIdx.push(i as int32);
	}
	lines.push(`Y\t${intsCsv(importIdx)}`);
	lines.push(`W\t${intsCsv(interfIdx)}`);
	for (const id of ctx.table.current.symbols.keys()) {
		const scoped = ctx.table.current.symbols.get(id);
		const key = identName(ctx.table.identCache, id);
		if (scoped != null && key != scoped.name) lines.push(`K\t${escapeP(key)}\t${w.idxSym(scoped)}`);
	}

	if (ctx.extensionRegistry != null) {
		for (const ext of extensionsOf(ctx.extensionRegistry)) {
			lines.push(`E\t${escapeP(ext.methodName)}\t${escapeP(ext.sourcePath)}\t${ext.isStatic ? 1 : 0}\t${ext.scopeDepth as int32}\t${w.idxSym(ext.sym)}`);
		}
	}

	for (const conv of ctx.converterTargetTypes.keys()) {
		lines.push(`C\t${w.idxSym(conv)}\t${w.idxType(ctx.converterTargetTypes.get(conv))}`);
	}

	for (const name of ctx.compilerFuncs.keys()) {
		const declared = ctx.compilerFuncs.get(name);
		if (declared == null) continue;
		lines.push(`P\t${escapeP(name)}\t${w.idxSym(declared)}`);
	}

	for (const spec of ctx.preludeInterf.keys()) {
		const members = ctx.preludeInterf.get(spec);
		if (members == null) continue;
		const idx: int32[] = [];
		for (const m of members) idx.push(w.idxSym(m));
		lines.push(`U\t${escapeP(spec)}\t${intsCsv(idx)}`);
	}
	for (const path of ctx.preludeModuleScopes.keys()) {
		const members = ctx.preludeModuleScopes.get(path);
		if (members == null) continue;
		const idx: int32[] = [];
		for (const m of members) idx.push(w.idxSym(m));
		lines.push(`M\t${escapeP(path)}\t${intsCsv(idx)}`);
	}
	for (const path of ctx.ownModules) lines.push(`O\t${escapeP(path)}`);

	lines.push(`D\t${escapeP(ctx.includeDirectives)}`);
	lines.push(`F\t${escapeP(ctx.compilerFlags)}`);
	lines.push(`X\t${escapeP(ctx.compileDirectives)}`);
	const variants: int32[] = [];
	for (const v of tables.duVariants) variants.push(w.idxType(v));
	lines.push(`Q\t${intsCsv(variants)}`);
	for (let i = 0; i < tables.dispatch.methodSyms.length; i += 1) {
		lines.push(`R\t${w.idxSym(tables.dispatch.classSyms[i])}\t${escapeP(tables.dispatch.methodNames[i])}\t${w.idxSym(tables.dispatch.methodSyms[i])}`);
	}
	for (const row of tables.ctorRoutines) lines.push(`A\t${w.idxSym(row.owner)}\t${w.idxSym(row.routine)}`);

	if (packDebug) console.log(`[pack] rows=${lines.length} joining at ms=${performance.now() - _w0}`);
	const blob = lines.join("\n");
	if (packDebug) console.log(`[pack] bytes=${blob.byteLength} at ms=${performance.now() - _w0}`);
	const okw = atomicWritePack(`${root}/${key}.pk`, blob);
	if (packDebug) console.log(`[pack] write ok=${okw ? 1 : 0} total ms=${performance.now() - _w0}`);
	collectUnusedPacks(nowSeconds());
	_writeMs = _writeMs + (performance.now() - _w0);
}

const PACK_UNUSED_SECONDS: float64 = 24 * 3600;

export function collectUnusedPacks(now: float64): void {
	collectStaleEntries(packBase(), now, [".pk", ".deps"], PACK_UNUSED_SECONDS);
}

export function tryLoadPreludePack(key: string, stamp: string, dispatchRegistry: DispatchRegistry = createDispatchRegistry()): CheckerContext | null {
	if (packDisabled()) return null;
	const _l0 = performance.now();
	const root = packRoot();
	ensureDir(root);
	const body = try readFile(`${root}/${key}.pk`) catch "";
	if (!body.startsWith(`${PACK_MAGIC}\nV\t${stamp}\n`)) {
		_loadMs = _loadMs + (performance.now() - _l0);
		_lastHit = false;
		return null;
	}
	const loaded = tryLoadPreludePackBody(body, dispatchRegistry);
	if (loaded != null) markUsed(`${root}/${key}.pk`, nowSeconds());
	_loadMs = _loadMs + (performance.now() - _l0);
	_lastHit = loaded != null;
	return loaded;
}

// Reader for the deps half. Returns null on any doubt (disabled, missing,
// empty, unknown/malformed row) — the caller falls back to the fresh parse
// path, which is always correct, just slower.
export function tryLoadPreludeDeps(key: string, stamp: string): PreludeDepsSnapshot | null {
	if (packDisabled()) return null;
	const root = packRoot();
	ensureDir(root);
	const body = try readFile(`${root}/${key}.deps`) catch "";
	if (!body.startsWith(`K\t${key}\t${stamp}\n`)) return null;
	const snap: PreludeDepsSnapshot = { mods: [], circulars: [] };
	const rd = new PackReader(body);
	while (rd.pos < rd.b.length && rd.b[rd.pos] != 10) rd.pos += 1;
	rd.pos += 1;
	while (true) {
		const tag = rd.startRow();
		if (tag < 0) break;
		if (rd.bad) return null;
		if (tag == 71) {
			snap.mods.push({ path: unescapeP(rd.str()), imports: [] });
		} else if (tag == 73 && snap.mods.length > 0) {
			const sourcePath = unescapeP(rd.str());
			const sourceSpecifier = unescapeP(rd.str());
			const names = splitCsv(rd.str());
			const aliases = splitCsv(rd.str());
			snap.mods[snap.mods.length - 1].imports.push({ sourcePath, sourceSpecifier, names, aliases });
		} else if (tag == 82) {
			const fromPath = unescapeP(rd.str());
			const toPath = unescapeP(rd.str());
			const cycle = splitCsv(rd.str());
			const importLine = rd.int() as int32;
			const importNames = splitCsv(rd.str());
			snap.circulars.push({ fromPath, toPath, cycle, importLine, importNames });
		} else {
			return null;
		}
		rd.endRow();
		if (rd.bad) return null;
	}
	if (snap.mods.length == 0) return null;
	return snap;
}

function tryLoadPreludePackBody(body: string, dispatchRegistry: DispatchRegistry): CheckerContext | null {
	const packDebug = env.get("MSC_PACK_DEBUG") != "";
	const _r0 = performance.now();
	const rd = new PackReader(body);
	rd.pos = rd.fieldEnd();
	if (rd.pos >= rd.b.length) return null;
	rd.pos += 1;
	if (packDebug) console.log(`[pack:r] reader ms=${performance.now() - _r0}`);

	const objects = new RowReader();
	const extNames: string[] = [];
	const extSources: string[] = [];
	const extStatic: boolean[] = [];
	const extDepth: int32[] = [];
	const extSym: int32[] = [];
	const convSym: int32[] = [];
	const convType: int32[] = [];
	const compilerFuncNames: string[] = [];
	const compilerFuncSym: int32[] = [];
	const interfSpecs: string[] = [];
	const interfMembers: int32[][] = [];
	const moduleScopePaths: string[] = [];
	const moduleScopeMembers: int32[][] = [];
	const ownModules: string[] = [];
	const aliasNames: string[] = [];
	const aliasSym: int32[] = [];
	let importIdx: int32[] = [];
	let exportIdx: int32[] = [];
	let includeDirectives = "";
	let compilerFlags = "";
	let compileDirectives = "";
	let variantIdx: int32[] = [];
	const dispClassIdx: int32[] = [];
	const dispNames: string[] = [];
	const dispMethodIdx: int32[] = [];
	const ctorOwnerIdx: int32[] = [];
	const ctorRoutineIdx: int32[] = [];

	while (true) {
		const tag = rd.startRow();
		if (tag < 0) break;
		if (rd.bad) return null;
		if (objects.readObjectRow(tag, rd)) {
			if (rd.bad) return null;
			continue;
		}
		if (tag == 86) {
			rd.endRow();
		} else if (tag == 69) {
			extNames.push(unescapeP(rd.str()));
			extSources.push(unescapeP(rd.str()));
			extStatic.push(rd.int() == 1);
			extDepth.push(rd.int() as int32);
			extSym.push(rd.int() as int32);
			rd.endRow();
		} else if (tag == 67) {
			convSym.push(rd.int() as int32);
			convType.push(rd.int() as int32);
			rd.endRow();
		} else if (tag == 80) {
			compilerFuncNames.push(unescapeP(rd.str()));
			compilerFuncSym.push(rd.int() as int32);
			rd.endRow();
		} else if (tag == 85) {
			interfSpecs.push(unescapeP(rd.str()));
			interfMembers.push(rd.ints());
			rd.endRow();
		} else if (tag == 77) {
			moduleScopePaths.push(unescapeP(rd.str()));
			moduleScopeMembers.push(rd.ints());
			rd.endRow();
		} else if (tag == 79) {
			ownModules.push(unescapeP(rd.str()));
			rd.endRow();
		} else if (tag == 75) {
			aliasNames.push(unescapeP(rd.str()));
			aliasSym.push(rd.int() as int32);
			rd.endRow();
		} else if (tag == 89) {
			importIdx = rd.ints();
			rd.endRow();
		} else if (tag == 87) {
			exportIdx = rd.ints();
			rd.endRow();
		} else if (tag == 68) {
			includeDirectives = unescapeP(rd.str());
			rd.endRow();
		} else if (tag == 70) {
			compilerFlags = unescapeP(rd.str());
			rd.endRow();
		} else if (tag == 88) {
			compileDirectives = unescapeP(rd.str());
			rd.endRow();
		} else if (tag == 81) {
			variantIdx = rd.ints();
			rd.endRow();
		} else if (tag == 82) {
			dispClassIdx.push(rd.int() as int32);
			dispNames.push(unescapeP(rd.str()));
			dispMethodIdx.push(rd.int() as int32);
			rd.endRow();
		} else if (tag == 65) {
			ctorOwnerIdx.push(rd.int() as int32);
			ctorRoutineIdx.push(rd.int() as int32);
			rd.endRow();
		} else {
			return null;
		}
		if (rd.bad) return null;
	}

	const types = objects.types;
	const syms = objects.syms;
	if (syms.length == 0) return null;
	if (packDebug) console.log(`[pack:r] rows parsed T=${types.length} N=${objects.nodes.length} S=${syms.length} ms=${performance.now() - _r0}`);

	if (!objects.linkTypesAndSymbols()) return null;
	if (packDebug) console.log(`[pack:r] T+S linked ms=${performance.now() - _r0}`);

	if (!objects.linkNodes(rd)) return null;
	if (packDebug) console.log(`[pack:r] N linked ms=${performance.now() - _r0}`);

	const cache = createIdentCache();
	const ctx = createContextWithCache(cache, dispatchRegistry);
	ctx.outOfTree = objects.nodes;
	ctx.extensionRegistry = createExtensionRegistry();
	for (let i = 0; i < syms.length; i += 1) {
		const s = syms[i];
		s.nameId = getIdentId(cache, s.name);
		if (objects.rootFlags[i] == 1) {
			(ctx.table.current.symbols as Map<int32, Symbol>).set(s.nameId, s);
		}
	}

	for (let i = 0; i < aliasNames.length; i += 1) {
		const si = aliasSym[i];
		if (si >= 0 && si < syms.length) (ctx.table.current.symbols as Map<int32, Symbol>).set(getIdentId(cache, aliasNames[i]), syms[si]);
	}
	for (const si of importIdx) {
		if (si >= 0 && si < syms.length) ctx.importSet.add(syms[si]);
	}
	for (const si of exportIdx) {
		if (si < 0 || si >= syms.length) continue;
		ctx.interfSet.add(syms[si]);
		ctx.interf.push(syms[si]);
	}

	for (let i = 0; i < extNames.length; i += 1) {
		const symRef = extSym[i];
		const extSymbol = symRef >= 0 && symRef < syms.length ? syms[symRef] : null as unknown as Symbol;
		registerExtension(ctx.extensionRegistry, createExtMethod(extNames[i], extSources[i], extStatic[i], extSymbol, extDepth[i]));
	}

	for (let i = 0; i < convSym.length; i += 1) {
		const si = convSym[i];
		const ti = convType[i];
		if (si >= 0 && si < syms.length && ti >= 0 && ti < types.length) ctx.converterTargetTypes.set(syms[si], types[ti]);
	}

	for (let i = 0; i < compilerFuncNames.length; i += 1) {
		const si = compilerFuncSym[i];
		if (si < 0 || si >= syms.length) continue;
		setFlag(syms[si], SymbolFlag.CompilerProc);
		ctx.compilerFuncs.set(compilerFuncNames[i], syms[si]);
	}
	for (let i = 0; i < interfSpecs.length; i += 1) {
		const members: Symbol[] = [];
		for (const si of interfMembers[i]) {
			if (si >= 0 && si < syms.length) members.push(syms[si]);
		}
		ctx.preludeInterf.set(interfSpecs[i], members);
		for (const m of members) ctx.preludeExports.add(m);
	}
	for (let i = 0; i < moduleScopePaths.length; i += 1) {
		const members: Symbol[] = [];
		for (const si of moduleScopeMembers[i]) {
			if (si >= 0 && si < syms.length) members.push(syms[si]);
		}
		ctx.preludeModuleScopes.set(moduleScopePaths[i], members);
	}
	for (const path of ownModules) ctx.ownModules.add(path);

	ctx.includeDirectives = includeDirectives;
	ctx.compilerFlags = compilerFlags;
	ctx.compileDirectives = compileDirectives;

	const tables = emptyPreludeTables();
	for (const k of variantIdx) {
		if (k < 0 || k >= types.length) return null;
		tables.duVariants.push(types[k]);
	}
	for (let i = 0; i < dispMethodIdx.length; i += 1) {
		const ci = dispClassIdx[i];
		const mi = dispMethodIdx[i];
		if (ci < 0 || ci >= syms.length || mi < 0 || mi >= syms.length) return null;
		tables.dispatch.classSyms.push(syms[ci]);
		tables.dispatch.methodNames.push(dispNames[i]);
		tables.dispatch.methodSyms.push(syms[mi]);
	}
	for (let i = 0; i < ctorOwnerIdx.length; i += 1) {
		const oi = ctorOwnerIdx[i];
		const ri = ctorRoutineIdx[i];
		if (oi < 0 || oi >= syms.length || ri < 0 || ri >= syms.length) return null;
		tables.ctorRoutines.push({ owner: syms[oi], routine: syms[ri], routineDecl: null });
	}
	ctx.preludeDispatchRecords = tables.dispatch;
	replayPreludeTables(tables, dispatchRegistry);

	if (packDebug) console.log(`[pack:r] done ms=${performance.now() - _r0}`);
	return ctx;
}


// ===== Tests =====
//
// Disk mechanics + escape roundtrips live here (self-contained ctx). The
// end-to-end "pack-loaded prelude behaves like a fresh one" contract is
// guarded by the emitted-C fixpoint ladder.

const PK_STAMP = "pk-test-stamp";

function pkEnterPrivateCache(): string {
	const prevHome = env.get("HOME");
	env.set("HOME", `out/test/preludePackHome.${performance.now()}`);
	env.set("MSC_PRELUDE_PACK", "1");
	return prevHome;
}

function pkLeavePrivateCache(prevHome: string): void {
	const home = env.get("HOME");
	env.delete("MSC_PRELUDE_PACK");
	if (prevHome == "") env.delete("HOME");
	else env.set("HOME", prevHome);
	removeAll(home);
}

function pkCtxWithOneSym(): CheckerContext {
	const ctx = makeTestCtx();
	const sym = makeSymbolState("pkStampFn", SymbolKind.Function, null, false, SymbolState.Hollow);
	sym.state = SymbolState.Checked;
	const st = emptyType();
	st.kind = TypeKind.Int32;
	sym.symbolType = st;
	sym.nameId = getIdentId(ctx.table.identCache, sym.name);
	(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
	return ctx;
}

function makeTestCtx(): CheckerContext {
	const ctx = createContextWithCache(createIdentCache());
	ctx.extensionRegistry = createExtensionRegistry();
	return ctx;
}

test "preludePack: write then load reconstructs symbols, types, nodes, exts, directives" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const sym = makeSymbolState("pkTestFn", SymbolKind.Function, null, false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		sym.symFlags = 2 as BitSet<SymbolFlag>;
		sym.modulePath = "std/pk/test.ms";
		const fnType = emptyType();
		fnType.kind = TypeKind.Function;
		fnType.typeName = "";
		fnType.typeNames = ["a", "b"];
		const p1 = emptyType();
		p1.kind = TypeKind.Int32;
		const p2 = emptyType();
		p2.kind = TypeKind.String;
		fnType.typeChildren = [p1, p2];
		fnType.typeReturn = null as unknown as Type;
		fnType.optionalFields = ["b"];
		sym.symbolType = fnType;
		const ov = makeSymbolState("pkTestFn", SymbolKind.Function, null, false, SymbolState.Hollow);
		ov.state = SymbolState.Checked;
		sym.overloads = [ov];
		// declNode + defaultParams exercise the N table: a FunctionDecl whose
		// body returns a binary expr, with one int literal default param.
		const zero = createNodeAt(NodeKind.NumberLiteral, { value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false } as NodeData, makeLoc(9, 8));
		const one = createNodeAt(NodeKind.NumberLiteral, { value: 1, isFloat: false, intVal: 1, outOfRangeText: "", isBitPattern: false } as NodeData, makeLoc(9, 12));
		const add = createNodeAt(NodeKind.BinaryExpr, { operator: "+", left: zero, right: one } as NodeData, makeLoc(9, 8));
		const ret = createNodeAt(NodeKind.ReturnStmt, { argument: add } as NodeData, makeLoc(9, 2));
		const body = createNodeAt(NodeKind.BlockStmt, { statements: [ret] } as NodeData, makeLoc(8, 30));
		const decl = createNodeAt(NodeKind.FunctionDecl, { fnName: "pkTestFn", params: ["start"], fnParamTypes: ["int32"], fnBody: body, fnFlags: "", fnReturnType: "int32", fnDefaults: [zero], nativeName: "", nameLocation: makeLoc(7, 9) } as NodeData, makeLoc(7, 1));
		decl.flags = decl.flags.incl(NodeFlag.OptionalChainEnd).incl(NodeFlag.ValueUnion);
		sym.declNode = decl;
		sym.defaultParams = [zero];
		const cache = ctx.table.identCache;
		sym.nameId = getIdentId(cache, sym.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
		ctx.includeDirectives = "runtime/core/system.h\nruntime/io/streams.h";
		ctx.compilerFlags = "-Ivendor/x -O2";
		ctx.compileDirectives = "vendor/crypto/a.c vendor/io/b.c";
		registerExtension(ctx.extensionRegistry, createExtMethod("pkExt", "std/pk/test.ms", true, sym, 0));
		ctx.compilerFuncs.set("pkRuntimeName", sym);

		const key = preludePackKey("stdpath-should-not-matter-for-roundtrip", ".test");
		assert packRoot().startsWith("out/test/"), `a pack test reached the machine-wide cache: ${packRoot()}`;
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkTestFn"));
		assert got != null;
		assert loaded.compilerFuncs.get("pkRuntimeName") == got, "a compilerFunc binding did not survive the pack";
		assert got.symbolKind == SymbolKind.Function;
		assert got.state == SymbolState.Checked;
		assert (got.symFlags as uint32) == 2;
		assert got.modulePath == "std/pk/test.ms";
		assert got.symbolType != null && got.symbolType.kind == TypeKind.Function;
		assert got.symbolType.typeNames.length == 2;
		assert got.symbolType.typeNames[1] == "b";
		assert got.symbolType.typeChildren[0].kind == TypeKind.Int32;
		assert got.symbolType.optionalFields != null && got.symbolType.optionalFields.length == 1 && got.symbolType.optionalFields[0] == "b", "a type's optional fields did not survive the pack";
		assert got.symbolType.typeChildren[0].optionalFields == null;
		assert got.overloads.length == 1 && got.overloads[0].name == "pkTestFn";
		// N-table roundtrip: declNode restored with full body structure.
		assert got.declNode != null;
		assert got.declNode.kind == NodeKind.FunctionDecl;
		const gd = got.declNode.data as FunctionDeclData;
		assert got.declNode.flags.has(NodeFlag.OptionalChainEnd) && got.declNode.flags.has(NodeFlag.ValueUnion), "a node flag past bit 31 did not survive the pack";
		assert gd.fnName == "pkTestFn";
		assert gd.params[0] == "start";
		const gbody = gd.fnBody.data as BlockStmtData;
		assert gbody.statements.length == 1;
		assert gbody.statements[0].kind == NodeKind.ReturnStmt;
		const gret = gbody.statements[0].data as ReturnStmtData;
		const gadd = gret.argument.data as BinaryExprData;
		assert gadd.operator == "+";
		const gl = gadd.left.data as NumberLiteralData;
		const gr = gadd.right.data as NumberLiteralData;
		assert gl.intVal == 0 && gr.intVal == 1;
		assert gl.value == 0 && gr.value == 1;
		assert got.defaultParams != null && got.defaultParams.length == 1;
		assert (got.defaultParams[0].data as NumberLiteralData).intVal == 0;
		assert loaded.includeDirectives == ctx.includeDirectives;
		assert loaded.compilerFlags == ctx.compilerFlags;
		assert loaded.compileDirectives == ctx.compileDirectives;
		const loadedExts = extensionsOf(loaded.extensionRegistry);
		assert loadedExts.length == 1;
		assert loadedExts[0].methodName == "pkExt";
		assert loadedExts[0].sym == got;
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}


test "preludePack: a macro symbol keeps its MacroDecl declaration node" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const sym = makeSymbolState("pkMacro", SymbolKind.Macro, null, false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		sym.nameId = getIdentId(ctx.table.identCache, sym.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
		const noStmts: Node[] = [];
		const body = createNodeAt(NodeKind.BlockStmt, { statements: noStmts } as NodeData, makeLoc(3, 1));
		const decl = createNodeAt(NodeKind.MacroDecl, { macroDeclName: "pkMacro", macroDeclParams: ["value"], macroDeclParamTypes: ["Node"], macroDeclReturnType: "Node", macroDeclBody: body } as NodeData, makeLoc(2, 1));
		sym.declNode = decl;
		const key = preludePackKey("macro-decl", ".test");
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkMacro"));
		assert got != null;
		assert got.declNode != null;
		assert got.declNode.kind == NodeKind.MacroDecl;
		const md = got.declNode.data as MacroDeclData;
		assert md.macroDeclName == "pkMacro";
		assert md.macroDeclParams.length == 1;
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: generic defaults and parameter identity survive cold and warm reads" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const sym = makeSymbolState("pkAt", SymbolKind.TypeAlias, noneType(), false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		sym.nameId = getIdentId(ctx.table.identCache, sym.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
		const t = createGenericParam("T");
		const k = createGenericParam("K");
		k.typeExtra = createKeyOfType(t);
		t.typeParamDefault = emptyType();
		t.typeParamDefault!.kind = TypeKind.String;
		k.typeParamDefault = t;
		const decl = createNodeAt(NodeKind.TypeAliasDecl, { aliasName: "pkAt", aliasType: "T", aliasIsDistinct: false, aliasGenericParams: "T,K", discriminantName: "", discriminantType: "", variantKeys: [], variantTypes: [], nameLocation: makeLoc(1, 1) }, makeLoc(1, 1));
		const annotation = createNodeAt(NodeKind.TypeAnnotation, { annotationType: "T" }, makeLoc(1, 12));
		annotation.typeExpr = createNodeAt(NodeKind.Identifier, { name: "T" }, makeLoc(1, 12));
		annotation.nodeType = t;
		decl.genericDefaults = [null, annotation];
		sym.declNode = decl;
		sym.typeParams = [t, k];
		const key = preludePackKey("type-params", ".test");
		assert tryLoadPreludePack(key, PK_STAMP) == null;
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkAt"));
		assert got != null;
		assert got.typeParams.length == 2;
		assert got.typeParams[0].typeName == "T" && got.typeParams[1].typeName == "K";
		const constraint = got.typeParams[1].typeExtra;
		assert constraint != null && constraint.kind == TypeKind.KeyOf;
		assert constraint.typeChildren[0] == got.typeParams[0];
		assert got.typeParams[0].typeParamDefault!.kind == TypeKind.String;
		assert got.typeParams[1].typeParamDefault == got.typeParams[0];
		const syntax = got.declNode!.genericDefaults;
		assert syntax != null;
		if (syntax != null) {
			assert syntax.length == 2;
			assert syntax[0] == null;
			const value = syntax[1];
			assert value != null;
			if (value != null) {
				assert value.nodeType == got.typeParams[0];
				assert value.typeExpr != null;
				if (value.typeExpr != null) assert value.typeExpr.kind == NodeKind.Identifier;
			}
		}
		const warm = tryLoadPreludePack(key, PK_STAMP);
		assert warm != null;
		const warmSym = warm.table.current.symbols.get(getIdentId(warm.table.identCache, "pkAt"));
		assert warmSym!.typeParams[1].typeParamDefault == warmSym!.typeParams[0];
		const path = `${packRoot()}/${key}.pk`;
		const packed = try readFile(path) catch "";
		writeFile(path, packed.replace(PACK_MAGIC, "MSPK8"));
		assert tryLoadPreludePack(key, PK_STAMP) == null;
		remove(path);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: a generic instance keeps the generic it was instantiated from and its checked arguments and type parameters" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const generic = makeSymbolState("pkPop", SymbolKind.Function, noneType(), false, SymbolState.Hollow);
		generic.state = SymbolState.Checked;
		generic.nameId = getIdentId(ctx.table.identCache, generic.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(generic.nameId, generic);
		const inScope = makeSymbolState("pkPop_int32", SymbolKind.Function, noneType(), false, SymbolState.Hollow);
		inScope.state = SymbolState.Checked;
		inScope.instantiatedFrom = generic;
		const param = createGenericParam("T");
		const arg = emptyType();
		arg.kind = TypeKind.String;
		inScope.instanceParams = [param];
		inScope.instanceArgs = [arg];
		inScope.nameId = getIdentId(ctx.table.identCache, inScope.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(inScope.nameId, inScope);
		const unlisted = makeSymbolState("pkShift", SymbolKind.Function, noneType(), false, SymbolState.Hollow);
		unlisted.state = SymbolState.Checked;
		const reachedOnlyByLink = makeSymbolState("pkShift_int32", SymbolKind.Function, noneType(), false, SymbolState.Hollow);
		reachedOnlyByLink.state = SymbolState.Checked;
		reachedOnlyByLink.instantiatedFrom = unlisted;
		reachedOnlyByLink.nameId = getIdentId(ctx.table.identCache, reachedOnlyByLink.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(reachedOnlyByLink.nameId, reachedOnlyByLink);
		const key = preludePackKey("instantiated-from", ".test");
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const gotGeneric = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkPop"));
		const gotInstance = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkPop_int32"));
		assert gotGeneric != null && gotInstance != null;
		assert gotInstance.instantiatedFrom == gotGeneric;
		assert gotInstance.instanceParams != null && gotInstance.instanceParams!.length == 1 && gotInstance.instanceParams![0].typeName == "T";
		assert gotInstance.instanceArgs != null && gotInstance.instanceArgs!.length == 1 && gotInstance.instanceArgs![0].kind == TypeKind.String;
		assert gotGeneric.instanceArgs == null && gotGeneric.instanceParams == null;
		const gotLinked = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkShift_int32"));
		assert gotLinked != null && gotLinked.instantiatedFrom != null;
		assert gotLinked.instantiatedFrom!.name == "pkShift";
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: a symbol keeps the flags above bit 31" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const sym = makeSymbolState("pkHelper", SymbolKind.Function, noneType(), false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		setFlag(sym, SymbolFlag.Exported);
		setFlag(sym, SymbolFlag.Inline);
		setFlag(sym, SymbolFlag.IteratorHelper);
		sym.nameId = getIdentId(ctx.table.identCache, sym.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
		const key = preludePackKey("high-flags", ".test");
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkHelper"));
		assert got != null;
		assert hasFlag(got, SymbolFlag.Exported) && hasFlag(got, SymbolFlag.Inline) && hasFlag(got, SymbolFlag.IteratorHelper);
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: a hit links a class and its constructor routine both ways and captures the row as the cold check did" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const owner = makeSymbolState("PkOwner", SymbolKind.Class, noneType(), false, SymbolState.Checked);
		const routine = makeSymbolState("PkOwner_init", SymbolKind.Function, noneType(), false, SymbolState.Checked);
		owner.ctorRoutine = routine;
		routine.ctorOwner = owner;
		owner.nameId = getIdentId(ctx.table.identCache, owner.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(owner.nameId, owner);
		const tables = emptyPreludeTables();
		tables.ctorRoutines.push({ owner, routine, routineDecl: null });
		const key = preludePackKey("ctor-routine", ".test");
		writePreludePack(key, PK_STAMP, ctx, tables);
		const outer = startCtorCapture();
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		const captured = endCtorCapture(outer);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, owner.name));
		assert got != null && got != owner;
		const gotRoutine = got.ctorRoutine;
		assert gotRoutine != null && gotRoutine != routine && gotRoutine.ctorOwner == got;
		assert captured.length == 1 && captured[0].owner == got && captured[0].routine == gotRoutine;
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: a node keeps a flag in bit 63" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const sym = makeSymbolState("pkFlagFn", SymbolKind.Function, noneType(), false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		sym.nameId = getIdentId(ctx.table.identCache, sym.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
		const node = createNodeAt(NodeKind.Program, { programStmts: [] } as NodeData, makeLoc(1, 1));
		node.flags = node.flags.incl(NodeFlag.PlainRelease).incl(NodeFlag.Sem);
		sym.declNode = node;
		const key = preludePackKey("node-high-flag", ".test");
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkFlagFn"));
		assert got != null && got.declNode != null;
		assert got.declNode.flags.has(NodeFlag.PlainRelease) && got.declNode.flags.has(NodeFlag.Sem);
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: exhaustive per-kind node roundtrip" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const sym = makeSymbolState("pkKindFn", SymbolKind.Function, null, false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		sym.symFlags = 3 as BitSet<SymbolFlag>;
		const st = emptyType();
		st.kind = TypeKind.Int32;
		sym.symbolType = st;
		sym.nameId = getIdentId(ctx.table.identCache, sym.name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);
		const nt = emptyType();
		nt.kind = TypeKind.Int32;
		nt.typeName = "int32";
		const ct = emptyType();
		ct.kind = TypeKind.Boolean;
		ct.typeName = "bool";
		const samples = pkSamples(sym, nt, ct);
		// Completeness tripwire: one sample per NodeKind member, in enum
		// order — extend pkSamples when NodeKind grows.
		assert samples.length == 92;
		for (let i = 0; i < samples.length; i += 1) {
			assert (samples[i].kind as int32) == i;
		}
		const program = createNodeAt(NodeKind.Program, { programStmts: samples } as NodeData, makeLoc(1, 1));
		sym.declNode = program;
		const key = preludePackKey("kind-roundtrip", ".test");
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkKindFn"));
		assert got != null;
		assert got.declNode != null;
		const stmts = (got.declNode.data as ProgramData).programStmts;
		assert stmts.length == samples.length;
		for (let i = 0; i < samples.length; i += 1) {
			const da = pkDumpNode(samples[i]);
			const db = pkDumpNode(stmts[i]);
			if (da != db) {
				console.log(`kind ${i} mismatch`);
				console.log(`  orig: ${da.slice(0, 300)}`);
				console.log(`  got : ${db.slice(0, 300)}`);
				assert false;
			}
		}
		remove(`${packRoot()}/${key}.pk`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: escaped and unicode names, negative and large int fields survive; a field that is not a number is a miss" {
	const prevHome = pkEnterPrivateCache();
	try {
		const ctx = makeTestCtx();
		const name = "pk é😀\t,\\\nend";
		const sym = makeSymbolState(name, SymbolKind.Function, null, false, SymbolState.Hollow);
		sym.state = SymbolState.Checked;
		sym.modulePath = name;
		sym.mutatedParams = 2147483647;
		sym.overloadIdx = -2147483648;
		sym.location = makeLoc(-7, 2147483647);
		const t = emptyType();
		t.kind = TypeKind.Int32;
		t.typeName = name;
		t.typeValue = -2147483648;
		sym.symbolType = t;
		const lit = createNodeAt(NodeKind.NumberLiteral, { value: 1, isFloat: false, intVal: -9223372036854775807, outOfRangeText: name, isBitPattern: false } as NodeData, makeLoc(-1, 2147483647));
		lit.flags = lit.flags.incl(NodeFlag.ValueUnion);
		const add = createNodeAt(NodeKind.BinaryExpr, { operator: "+", left: lit, right: lit } as NodeData, makeLoc(3, 4));
		sym.declNode = add;
		sym.nameId = getIdentId(ctx.table.identCache, name);
		(ctx.table.current.symbols as Map<int32, Symbol>).set(sym.nameId, sym);

		const key = preludePackKey("escape-and-range-probe", ".test");
		assert packRoot().startsWith("out/test/"), `a pack test reached the machine-wide cache: ${packRoot()}`;
		writePreludePack(key, PK_STAMP, ctx, emptyPreludeTables());
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, name));
		assert got != null;
		assert got.name == name && got.modulePath == name;
		assert got.mutatedParams == 2147483647 && got.overloadIdx == -2147483648;
		assert got.location.line == -7 && got.location.column == 2147483647;
		assert got.symbolType.typeName == name && got.symbolType.typeValue == -2147483648;
		const gl = (got.declNode.data as BinaryExprData).left;
		assert gl.location.line == -1 && gl.location.column == 2147483647 && gl.flags.has(NodeFlag.ValueUnion);
		const gd = gl.data as NumberLiteralData;
		assert gd.intVal == -9223372036854775807 && gd.outOfRangeText == name;

		const path = `${packRoot()}/${key}.pk`;
		const text = try readFile(path) catch "";
		const lines = text.split("\n");
		let tRow = -1;
		let binRow = -1;
		for (let i = 0; i < lines.length; i += 1) {
			if (tRow < 0 && lines[i].startsWith("T\t")) tRow = i;
			if (binRow < 0 && lines[i].startsWith("N\t") && lines[i].split("\t")[2] == `${NodeKind.BinaryExpr as int32}`) binRow = i;
		}
		assert tRow >= 0 && binRow >= 0;
		const header = lines[tRow].split("\t");
		header[2] = "x1";
		const payload = lines[binRow].split("\t");
		payload[20] = "q";
		const broken: string[] = [];
		for (let i = 0; i < lines.length; i += 1) broken.push(i == tRow ? header.join("\t") : i == binRow ? payload.join("\t") : lines[i]);
		writeFile(path, broken.join("\n"));
		assert tryLoadPreludePack(key, PK_STAMP) == null, "a row with a field that is not a number loaded";
		const onlyHeader: string[] = [];
		for (let i = 0; i < lines.length; i += 1) onlyHeader.push(i == tRow ? header.join("\t") : lines[i]);
		writeFile(path, onlyHeader.join("\n"));
		assert tryLoadPreludePack(key, PK_STAMP) == null, "a type row with a non-numeric kind loaded";
		const onlyPayload: string[] = [];
		for (let i = 0; i < lines.length; i += 1) onlyPayload.push(i == binRow ? payload.join("\t") : lines[i]);
		writeFile(path, onlyPayload.join("\n"));
		assert tryLoadPreludePack(key, PK_STAMP) == null, "a node payload with a non-numeric index loaded";
		remove(path);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: corrupt entry is a miss" {
	const prevHome = pkEnterPrivateCache();
	try {
		const key = preludePackKey("corrupt-probe", ".test");
		const root = packRoot();
		if (root != "") {
			ensureDir(root);
			writeFile(`${root}/${key}.pk`, "garbage\nnot a pack\n");
			const loaded = tryLoadPreludePack(key, PK_STAMP);
			assert loaded == null;
			remove(`${root}/${key}.pk`);
		}
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: deps snapshot roundtrip through the .deps file" {
	const prevHome = pkEnterPrivateCache();
	try {
		const key = preludePackKey("deps-roundtrip-probe", ".depstest");
		// Snapshot with the awkward corners: empty name/alias lists, an
		// import of the last G row, a circular record with a multi-hop
		// cycle, and a path containing separator bytes (\t and ,).
		writePreludeDeps(key, PK_STAMP, {
			mods: [
				{
					path: "/std/core/a.ms",
					imports: [
						{ names: ["x", "y"], aliases: ["x", "y2"], sourcePath: "/std/core/b,ms", sourceSpecifier: "./b\tws" },
						{ names: [], aliases: [], sourcePath: "/std/sub/c.ms", sourceSpecifier: "std/sub/c" },
					],
				},
				{ path: "/std/core/b,ms", imports: [] },
			],
			circulars: [
				{ fromPath: "/std/core/a.ms", toPath: "/std/core/b.ms", cycle: ["/std/core/a.ms", "/std/core/b.ms", "/std/core/a.ms"], importLine: 3, importNames: ["z"] },
			],
		});
		const loaded = tryLoadPreludeDeps(key, PK_STAMP);
		assert loaded != null;
		assert loaded.mods.length == 2;
		assert loaded.mods[0].path == "/std/core/a.ms";
		assert loaded.mods[0].imports.length == 2;
		assert loaded.mods[0].imports[0].names.length == 2;
		assert loaded.mods[0].imports[0].names[1] == "y";
		assert loaded.mods[0].imports[0].aliases[1] == "y2";
		assert loaded.mods[0].imports[0].sourcePath == "/std/core/b,ms";
		assert loaded.mods[0].imports[0].sourceSpecifier == "./b\tws";
		assert loaded.mods[0].imports[1].names.length == 0;
		assert loaded.mods[0].imports[1].aliases.length == 0;
		assert loaded.mods[1].path == "/std/core/b,ms";
		assert loaded.mods[1].imports.length == 0;
		assert loaded.circulars.length == 1;
		assert loaded.circulars[0].fromPath == "/std/core/a.ms";
		assert loaded.circulars[0].toPath == "/std/core/b.ms";
		assert loaded.circulars[0].cycle.length == 3;
		assert loaded.circulars[0].cycle[2] == "/std/core/a.ms";
		assert loaded.circulars[0].importLine == 3;
		assert loaded.circulars[0].importNames[0] == "z";
		assert tryLoadPreludeDeps(preludePackKey("deps-roundtrip-probe", ".other-backend"), PK_STAMP) == null;
		remove(`${packRoot()}/${key}.deps`);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: corrupt deps file is a miss" {
	const prevHome = pkEnterPrivateCache();
	try {
		const key = preludePackKey("deps-corrupt-probe", ".depstest");
		const root = packRoot();
		if (root != "") {
			ensureDir(root);
			writeFile(`${root}/${key}.deps`, "G\t/ok.ms\nQ\tbogus row\n");
			const loaded = tryLoadPreludeDeps(key, PK_STAMP);
			assert loaded == null;
			remove(`${root}/${key}.deps`);
		}
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: the key ignores build.ms extras — the pack and its deps hold std only" {
	setExtraGlobalImports([]);
	const bare = preludePackKey("key-extras-probe", ".keytest");
	setExtraGlobalImports(["/probe/converters"]);
	const withExtra = preludePackKey("key-extras-probe", ".keytest");
	setExtraGlobalImports([]);
	assert bare == withExtra;
}

test "preludePack: the key follows the std PATH — the rows it guards are absolute paths into one tree" {
	assert preludePackKey("/one/std", ".keytest") != preludePackKey("/two/std", ".keytest");
}

test "preludePack: interleaved compilers keep their typed preludes" {
	const prevHome = pkEnterPrivateCache();
	const savedStamp = _toolStamp;
	const savedStdHash = _stdTreeHash;
	const savedStdPath = _stdTreeHashPath;
	let firstKey = "";
	let secondKey = "";
	try {
		_toolStamp = "compiler-a";
		firstKey = preludePackKey("stamp-probe", ".test");
		const firstStamp = preludePackStamp("stamp-probe");
		writePreludePack(firstKey, firstStamp, pkCtxWithOneSym(), emptyPreludeTables());
		_toolStamp = "compiler-b";
		secondKey = preludePackKey("stamp-probe", ".test");
		const secondStamp = preludePackStamp("stamp-probe");
		const second = pkCtxWithOneSym();
		const secondSym = second.table.current.symbols.get(getIdentId(second.table.identCache, "pkStampFn"));
		if (secondSym != null) secondSym.symbolType.kind = TypeKind.String;
		writePreludePack(secondKey, secondStamp, second, emptyPreludeTables());
		assert tryLoadPreludePack(firstKey, secondStamp) == null;
		_toolStamp = "compiler-a";
		const first = tryLoadPreludePack(preludePackKey("stamp-probe", ".test"), preludePackStamp("stamp-probe"));
		assert first != null;
		if (first != null) {
			const sym = first.table.current.symbols.get(getIdentId(first.table.identCache, "pkStampFn"));
			assert sym != null;
			if (sym != null) assert sym.symbolType.kind == TypeKind.Int32;
		}
		_toolStamp = "compiler-b";
		const other = tryLoadPreludePack(preludePackKey("stamp-probe", ".test"), preludePackStamp("stamp-probe"));
		assert other != null;
		if (other != null) {
			const sym = other.table.current.symbols.get(getIdentId(other.table.identCache, "pkStampFn"));
			assert sym != null;
			if (sym != null) assert sym.symbolType.kind == TypeKind.String;
		}
	} finally {
		remove(`${packRoot()}/${firstKey}.pk`);
		remove(`${packRoot()}/${secondKey}.pk`);
		_toolStamp = savedStamp;
		_stdTreeHash = savedStdHash;
		_stdTreeHashPath = savedStdPath;
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: interleaved compilers keep their dependency graphs" {
	const prevHome = pkEnterPrivateCache();
	const savedStamp = _toolStamp;
	const savedStdHash = _stdTreeHash;
	const savedStdPath = _stdTreeHashPath;
	let firstKey = "";
	let secondKey = "";
	try {
		_toolStamp = "compiler-a";
		firstKey = preludePackKey("deps-stamp-probe", ".depstest");
		const firstStamp = preludePackStamp("deps-stamp-probe");
		writePreludeDeps(firstKey, firstStamp, { mods: [{ path: "/std/core/a.ms", imports: [] }], circulars: [] });
		_toolStamp = "compiler-b";
		secondKey = preludePackKey("deps-stamp-probe", ".depstest");
		const secondStamp = preludePackStamp("deps-stamp-probe");
		writePreludeDeps(secondKey, secondStamp, { mods: [{ path: "/std/core/b.ms", imports: [] }], circulars: [] });
		assert tryLoadPreludeDeps(firstKey, secondStamp) == null;
		_toolStamp = "compiler-a";
		const first = tryLoadPreludeDeps(preludePackKey("deps-stamp-probe", ".depstest"), preludePackStamp("deps-stamp-probe"));
		assert first != null;
		if (first != null) assert first.mods[0].path == "/std/core/a.ms";
		_toolStamp = "compiler-b";
		const second = tryLoadPreludeDeps(preludePackKey("deps-stamp-probe", ".depstest"), preludePackStamp("deps-stamp-probe"));
		assert second != null;
		if (second != null) assert second.mods[0].path == "/std/core/b.ms";
	} finally {
		remove(`${packRoot()}/${firstKey}.deps`);
		remove(`${packRoot()}/${secondKey}.deps`);
		_toolStamp = savedStamp;
		_stdTreeHash = savedStdHash;
		_stdTreeHashPath = savedStdPath;
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: a load leaves a peer's in-flight write alone" {
	const prevHome = pkEnterPrivateCache();
	try {
		const key = preludePackKey("inflight-probe", ".test");
		const root = packRoot();
		ensureDir(root);
		tryLoadPreludePack(key, PK_STAMP);
		const tmp = `${root}/${key}.pk.tmp.1`;
		writeFile(tmp, "half a pack");
		tryLoadPreludePack(key, PK_STAMP);
		assert exists(tmp), "a load swept another process's in-flight write";
		remove(tmp);
	} finally {
		pkLeavePrivateCache(prevHome);
	}
}

test "preludePack: a format keeps a peer's pack and in-flight write" {
	const prevHome = pkEnterPrivateCache();
	const base = `${env.get("HOME")}/.metascript/cache/prelude`;
	const peer = `${base}/peer-format.pk`;
	const pending = `${base}/peer-format.pk.tmp.1`;
	const marker = `${base}/.version`;
	const previousMarker = try readFile(marker) catch "";
	try {
		ensureDir(base);
		writeFile(marker, "MSPK0");
		writeFile(peer, "peer-owned pack");
		writeFile(pending, "peer-owned in-flight write");
		const key = preludePackKey("format-probe", ".test");
		writePreludePack(key, PK_STAMP, pkCtxWithOneSym(), emptyPreludeTables());
		assert tryLoadPreludePack(key, PK_STAMP) != null;
		const own = packRoot();
		for (const foreign of ["MSPK2", "MSPK10"]) {
			ensureDir(`${base}/${foreign}`);
			writeFile(`${base}/${foreign}/${key}.pk`, "another compiler's pack");
		}
		assert tryLoadPreludePack(key, PK_STAMP) != null;
		writePreludePack(key, PK_STAMP, pkCtxWithOneSym(), emptyPreludeTables());
		assert exists(`${own}/${key}.pk`);
		for (const foreign of ["MSPK2", "MSPK10"]) {
			assert exists(`${base}/${foreign}/${key}.pk`), `${foreign} lost its pack`;
		}
		const saved = try readFile(peer) catch "";
		const inFlight = try readFile(pending) catch "";
		const currentMarker = try readFile(marker) catch "";
		assert saved == "peer-owned pack";
		assert inFlight == "peer-owned in-flight write";
		assert currentMarker == "MSPK0";
		remove(`${own}/${key}.pk`);
		remove(`${own}/${key}.deps`);
	} finally {
		remove(peer);
		remove(pending);
		if (previousMarker != "") writeFile(marker, previousMarker);
		else remove(marker);
		pkLeavePrivateCache(prevHome);
	}
}

test "the prelude pack key moves with the parser defines" {
	const saved = getParserDefines();
	setParserDefines(createDefineTable());
	const plain = preludePackKey("/std", ".cms");
	const solana = createDefineTable();
	defineSymbol(solana, "solana", "true");
	setParserDefines(solana);
	const keyed = preludePackKey("/std", ".cms");
	setParserDefines(saved);
	assert plain != keyed;
}

test "a pack is written even when the collector removed its emptied format directory after the writer created it" {
	const root = `/tmp/msc-pack-rmdir-${performance.now()}`;
	const dir = `${root}/fmt`;
	ensureDir(dir);
	removeAll(dir);
	assert atomicWritePack(`${dir}/k.pk`, "pack");
	assert (try readFile(`${dir}/k.pk`) catch "") == "pack";
	removeAll(root);
}

test "a pack unused for a day is collected with its deps record, a pack used within the day stays" {
	const saved = env.get("MSC_GLOBAL_CACHE_DIR");
	const root = `/tmp/msc-pack-age-${performance.now()}`;
	env.set("MSC_GLOBAL_CACHE_DIR", root);
	try {
		const dir = packRoot();
		ensureDir(dir);
		writeFile(`${dir}/old.pk`, "pack");
		writeFile(`${dir}/old.deps`, "deps");
		const written = nowSeconds();
		collectUnusedPacks(written + 2 * 3600);
		assert exists(`${dir}/old.pk`) && exists(`${dir}/old.deps`);
		collectUnusedPacks(written + 25 * 3600);
		assert !exists(`${dir}/old.pk`) && !exists(`${dir}/old.deps`);
	} finally {
		env.set("MSC_GLOBAL_CACHE_DIR", saved);
		removeAll(root);
	}
}
