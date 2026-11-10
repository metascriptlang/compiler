import {
	escapeP,
	unescapeP,
	intsCsv,
	PackReader,
	startRow,
	int,
	str,
	ints,
	RowWriter,
	enqSym,
	enqType,
	enqNode,
	idxSym,
	idxType,
	idxNode,
	closeOver,
	emitObjectRows,
	RowReader,
	readObjectRow,
	linkTypesAndSymbols,
	linkNodes,
	FieldRole,
	FieldRoleKind,
} from "./rowCodec";
import { Symbol, Type, Node, AttachedOp, TypeFlag, CallingConvention } from "../ast/node";
import {
	CheckerContext,
	CheckerError,
	Severity,
	GcMode,
	ExtensionRegistry,
	ExtensionMethod,
	ExportRegistry,
	ExportedSymInfo,
	ModuleExports,
	JsImportEntry,
	MacroConverter,
	CheckedInstantiation,
	LockedMove,
	DispatchRegistry,
	DispMethodEntry,
	createContextWithCache,
	createExtensionRegistry,
	registerModuleExports,
	moduleItemId,
	moduleItemPaths,
	DefaultsRows,
	defaultsRows,
	replayDefaults,
	decodedRoutineFlagTextKeys,
	prewarmRoutineFlagTexts,
} from "./context";
import { Scope, SymbolTable, ScopeKind, decodedRoutineFlagKeys, prewarmRoutineFlags } from "./symbol";
import { IdentCache, getIdentId } from "./idents";
import { InitTracker } from "./initTracker";
import { AffineTracker } from "./spawnAffinity";
import { TargetInfo, wellKnownTypes, maybeCacheSize, maybeCacheKeys, maybeCacheTypes, replayMaybeCache, duVariantMark, duVariantsFrom, replayDuVariants, HeldBeyondRows, heldBeyondRows, replayHeldBeyond } from "./types";
import { InstanceHookRows, instanceHookRows, replayInstanceHooks, registeredModuleCount, localGenericCount } from "./instantiate";
import { effectsCheckedModules, effectsAtRestAfter, restoreEffectsAfterPrelude } from "./effects";
import { forwardTablesPending } from "./resolvePass";
import { createGraphPreludeContext, enterComptimeOuter, checksInFlight } from "./checkPass";
import { defaultGlobalImports, extraGlobalImports, modulePassIdentity } from "./prelude";
import { KeyedOp, opMark, opsFrom, replayOps, OpCanonRows, opCanonRows, replayOpCanonRows, opTablesAtRest } from "../codegen/c/types";
import { buildModuleNameRoots, rootedModuleKey } from "../codegen/c/names";
import { linkFlags, linkObjects } from "../utils/linkState";
import { TransAmDb, TaCheckRecord, dbCheckRecordMissing, dbRestoreCheck, dbStdUnitBlocker } from "../compiler/transam/index";
import { TaQueryKind, TaDurability } from "../compiler/transam/revision";
import { macroCompileCount, macroPreprocessCount } from "../compiler/meta/expand";
import { engineCompiledNames } from "../codegen/raiser/eval";
import { comptimeRunCount } from "../compiler/meta/hostPolicy";
import { ModuleGraph, findModule } from "../module/graph";
import { ResolverConfig } from "../module/resolver";
import { getParserDefines } from "../parser/context";
import { defineIdentity } from "../compiler/defines";
import { globalCacheRoot } from "../utils/cachePaths";
import { resolveRuntimeDir } from "../utils/path";
import { collectStaleEntries, markUsed, nowSeconds } from "../utils/stampDirs";
import { hashContent } from "../utils/contentHash";
import { readFile, writeFile, ensureDir, rename, remove } from "std/fs";
import { env } from "std/process";

const STD_UNIT_MAGIC = "MSSU1";
const STD_UNIT_UNUSED_SECONDS: float64 = 24 * 3600;
const MAX_ROW_COUNT: int64 = 100000000;

function encodedAs(column: string): FieldRole {
	return new FieldRole(FieldRoleKind.Encoded, column);
}

function derivedAs(why: string): FieldRole {
	return new FieldRole(FieldRoleKind.Derived, why);
}

function notWritten(why: string): FieldRole {
	return new FieldRole(FieldRoleKind.WrittenAsNull, why);
}

function refusedUnlessNull(why: string): FieldRole {
	return new FieldRole(FieldRoleKind.MustBeNull, why);
}

const NODE_KEYED_UNREAD = "own-tree nodes; encoded anyway, because an instance body re-checked in this context could reach one";

export const CHECKER_CONTEXT_FIELD_ROLES: { [K in keyof CheckerContext]-?: FieldRole } = {
	table: encodedAs("scope rows 7/8: Global and Module scopes, the chain above current and above each boundary, in allScopes order"),
	errors: encodedAs("error rows 9/!: hints included; the writer refuses a prelude module with an error or a warning"),
	gcMode: encodedAs("scalar row 0"),
	targetOs: encodedAs("scalar row 0"),
	targetInfo: derivedAs("the base's TargetInfo, stamped by checkModuleGraph and copied into each module context as injectPrelude copies it"),
	appMode: encodedAs("scalar row 0"),
	stdRoot: encodedAs("scalar row 0"),
	currentFunction: encodedAs("reference row 1"),
	currentActor: encodedAs("reference row 1"),
	instantiationSites: encodedAs("row 3"),
	staticBlockClass: encodedAs("reference row 1"),
	staticBlockPending: encodedAs("node list row 2"),
	readonlyBoundary: encodedAs("scope header row 7"),
	capturedSyms: encodedAs("row j"),
	identifierMoves: encodedAs("node list row 2"),
	refillTarget: encodedAs("reference row 1"),
	refillValue: encodedAs("reference row 1"),
	lockedMoves: encodedAs("row 4"),
	staticInitBoundary: encodedAs("scope header row 7"),
	hookBodyBoundary: encodedAs("scope header row 7"),
	pendingSpawnThunk: encodedAs("scalar row 0"),
	awaitedCall: encodedAs("reference row 1"),
	awaitedPayload: encodedAs("reference row 1"),
	typeTestDepth: encodedAs("scalar row 0"),
	inLoop: encodedAs("scalar row 0"),
	inSwitch: encodedAs("scalar row 0"),
	computedGotoMarks: encodedAs("node list row 2"),
	decoratorsPending: encodedAs("scalar row 0"),
	inTestBlock: encodedAs("scalar row 0"),
	moduleGraph: derivedAs("module: the graph of this build (asserted at write); base: null"),
	currentModule: derivedAs("module: the graph's Module of the path (asserted at write); base: null"),
	topProgram: encodedAs("reference row 1"),
	exportRegistry: derivedAs("module: the db's registry (asserted at write), restored from rows z/Z/Y/a; base: its own registry, asserted empty"),
	dispatchRegistry: derivedAs("the db's registry (asserted at write), restored from rows r/R/u/U/p/P"),
	preludeDispatchRecords: refusedUnlessNull("a graph prelude seeds no dispatch records"),
	adoptedDecls: encodedAs("row L; " + NODE_KEYED_UNREAD),
	adoptStmt: notWritten("collect hook of the module's own top level (collectPass collectTopLevelStmt, collectOneStatement); a later reader of a restored context collects none of its statements"),
	adoptedParams: encodedAs("row M; " + NODE_KEYED_UNREAD),
	boundIdents: encodedAs("row I; " + NODE_KEYED_UNREAD),
	inferredNeeds: encodedAs("row W; " + NODE_KEYED_UNREAD),
	inferredOwners: encodedAs("row X; " + NODE_KEYED_UNREAD),
	compilerFuncs: encodedAs("row F of the base; a module context shares the base's map (asserted at write), as injectPrelude does"),
	extensionRegistry: encodedAs("reference row 1: an index into the registry rows g/G"),
	macroConverters: encodedAs("row k"),
	converterTargetTypes: encodedAs("row l"),
	expansionFriends: encodedAs("rows Y/y; " + NODE_KEYED_UNREAD),
	runtimeConverters: encodedAs("row m"),
	macroExpansionDepth: encodedAs("scalar row 0"),
	jsxMacroArgDepth: encodedAs("scalar row 0"),
	jsxConsumer: encodedAs("reference row 1"),
	inferredReturn: encodedAs("reference row 1"),
	inferredReturnStmts: encodedAs("node list row 2"),
	inferredReturnTries: encodedAs("node list row 2"),
	includeDirectives: encodedAs("scalar row 0"),
	jsImportRegistry: encodedAs("rows n/@"),
	compileDirectives: encodedAs("scalar row 0"),
	compilerFlags: encodedAs("scalar row 0"),
	cancelCtx: derivedAs("module: db.cancelCtx, as the bind passes it (asserted at write); base: its constructor value"),
	cancelVersion: encodedAs("scalar row 0"),
	modulePath: encodedAs("scalar row 0"),
	symRecords: notWritten("editor suggest records: the LSP reads them from checks of its own db (completion.ms); a one-shot graph check never serves them"),
	symRecordsOff: encodedAs("scalar row 0"),
	compileTimeBodyDepth: encodedAs("scalar row 0"),
	matchArmExpected: encodedAs("reference row 1"),
	armTails: encodedAs("node list row 2"),
	initTracker: encodedAs("row J"),
	ctorExits: encodedAs("row 5"),
	ctorExitsNext: encodedAs("row 6"),
	affineTracker: encodedAs("row K"),
	strictNullChecks: encodedAs("scalar row 0"),
	inTryExpr: encodedAs("scalar row 0"),
	tryGuardedFunction: encodedAs("reference row 1"),
	genericInstDepth: encodedAs("scalar row 0"),
	generatedInstances: encodedAs("node list row 2"),
	procInstCache: encodedAs("rows o/O"),
	typeInstCache: encodedAs("rows p/P"),
	pendingHoisted: encodedAs("node list row 2"),
	pendingTrailing: encodedAs("node list row 2"),
	condEvalDepth: encodedAs("scalar row 0"),
	inGenericContext: encodedAs("scalar row 0"),
	stmtPosExpr: encodedAs("reference row 1"),
	typeExprSlot: encodedAs("reference row 1"),
	calleeExpr: encodedAs("reference row 1"),
	conversionOperand: encodedAs("reference row 1"),
	conversionTarget: encodedAs("reference row 1"),
	constContext: encodedAs("row Z; " + NODE_KEYED_UNREAD),
	disambTable: encodedAs("row q"),
	disambAfterCheck: encodedAs("row r"),
	itemModule: encodedAs("scalar row 0; the load asserts it equals the replayed moduleItemId"),
	nextItem: encodedAs("scalar row 0"),
	localTypeNames: encodedAs("row s"),
	pendingLocalTypeDecls: encodedAs("node list row 2"),
	liftedLocalTypeDecls: encodedAs("node list row 2"),
	outOfTree: derivedAs("the reader's node table: every node the unit restores, which the restored symbols and flow graph name"),
	flowNodes: derivedAs("empty: a unit writes no flow graph, and a clone of a restored body is bound again into its host"),
	preludeCtx: derivedAs("module: the restored base (asserted at write); base: null"),
	globalImportsCtx: refusedUnlessNull("no build.ms global import is visible to a std module"),
	instantiatingCtx: encodedAs("reference row 1: a context of the unit, refused otherwise"),
	interf: encodedAs("row t"),
	interfSet: encodedAs("row u"),
	interfNames: encodedAs("rows v/V"),
	explicitExportNames: encodedAs("row x"),
	importSet: encodedAs("row y"),
	shadowedImports: encodedAs("row A"),
	usedImports: encodedAs("row z"),
	preludeInterf: encodedAs("rows B/b"),
	preludeExports: encodedAs("row C"),
	preludeModuleScopes: encodedAs("rows D/d"),
	ownModules: encodedAs("row E"),
};

export const SYMBOL_TABLE_FIELD_ROLES: { [K in keyof SymbolTable]-?: FieldRole } = {
	current: encodedAs("scope header row 7"),
	allScopes: encodedAs("scope rows 8; a Function, Block, Class or Loop scope off every carried chain is dropped: no node or symbol holds one (instantiate.ms releaseInstanceBody), adopt.ms moduleSymbols reads Module scopes only, and a local generic's scope is asserted released at write"),
	identCache: derivedAs("the base's cache, shared by every context of the compilation"),
};

export const SCOPE_FIELD_ROLES: { [K in keyof Scope]-?: FieldRole } = {
	symbols: encodedAs("scope row 8: name ids and symbols in insertion order"),
	scopeKind: encodedAs("scope row 8"),
	parent: encodedAs("scope row 8: an earlier carried scope"),
	privateAccess: encodedAs("scope row 8"),
	friendModules: encodedAs("scope row 8"),
};

export const IDENT_CACHE_FIELD_ROLES: { [K in keyof IdentCache]-?: FieldRole } = {
	buckets: derivedAs("rebuilt by interning the names in id order"),
	counter: derivedAs("rebuilt by interning the names in id order"),
	names: encodedAs("row w"),
};

export const EXTENSION_REGISTRY_FIELD_ROLES: { [K in keyof ExtensionRegistry]-?: FieldRole } = {
	own: encodedAs("registry row G"),
	byNameHead: derivedAs("relinked from own in order, as appendExtension links it"),
	byNameTail: derivedAs("relinked from own in order, as appendExtension links it"),
	byNameNext: derivedAs("relinked from own in order, as appendExtension links it"),
	byNamePrev: derivedAs("relinked from own in order, as appendExtension links it"),
	base: encodedAs("registry row G"),
	baseCount: encodedAs("registry row G"),
	sealed: encodedAs("registry row G"),
	truncations: encodedAs("registry row G"),
	exportLayer: encodedAs("registry row G"),
	sourceSeen: encodedAs("registry row G"),
	sourceTruncations: encodedAs("registry row G"),
};

export const EXTENSION_METHOD_FIELD_ROLES: { [K in keyof ExtensionMethod]-?: FieldRole } = {
	methodName: encodedAs("extension row X"),
	sourcePath: encodedAs("extension row X"),
	isStatic: encodedAs("extension row X"),
	sym: encodedAs("extension row X"),
	scopeDepth: encodedAs("extension row X"),
};

export const EXPORT_REGISTRY_FIELD_ROLES: { [K in keyof ExportRegistry]-?: FieldRole } = {
	entries: encodedAs("rows z/Z, in registration order"),
	moduleIndex: derivedAs("registerModuleExports in entry order"),
	cTags: encodedAs("row a"),
};

export const MODULE_EXPORTS_FIELD_ROLES: { [K in keyof ModuleExports]-?: FieldRole } = {
	modulePath: encodedAs("row Z"),
	symbols: encodedAs("rows Y"),
};

export const EXPORTED_SYM_INFO_FIELD_ROLES: { [K in keyof ExportedSymInfo]-?: FieldRole } = {
	name: encodedAs("row Y"),
	sym: encodedAs("row Y"),
	ext: encodedAs("row Y: an index into the extension rows"),
	overloadExts: encodedAs("row Y: indexes into the extension rows"),
	converterTargetType: encodedAs("row Y"),
	keep: derivedAs("the reader's node table, as each restored context's outOfTree"),
};

export const DISPATCH_REGISTRY_FIELD_ROLES: { [K in keyof DispatchRegistry]-?: FieldRole } = {
	entries: encodedAs("rows r/R"),
	byClass: encodedAs("rows u/U"),
	bySym: encodedAs("rows p/P"),
	capture: refusedUnlessNull("no capture runs in a graph check"),
	version: encodedAs("row r"),
	readSink: refusedUnlessNull("no cached query tracks dispatch reads between checks"),
	seeded: refusedUnlessNull("empty: a graph prelude seeds no dispatch records"),
};

export const DISP_METHOD_ENTRY_FIELD_ROLES: { [K in keyof DispMethodEntry]-?: FieldRole } = {
	classSym: encodedAs("row R"),
	methodName: encodedAs("row R"),
	sym: encodedAs("row R"),
	overloaded: encodedAs("row R"),
	version: encodedAs("row R"),
};

export const INIT_TRACKER_FIELD_ROLES: { [K in keyof InitTracker]-?: FieldRole } = {
	initialized: encodedAs("row J"),
	currentBlock: encodedAs("row J"),
	leftPartOfAsgn: encodedAs("row J"),
	assignTarget: encodedAs("row J"),
	definiteTarget: encodedAs("row J"),
	argIdents: encodedAs("row J"),
	pendingReads: encodedAs("row J"),
	declScopes: encodedAs("row J"),
	declBlocks: encodedAs("row J"),
	outParams: encodedAs("row J"),
};

export const AFFINE_TRACKER_FIELD_ROLES: { [K in keyof AffineTracker]-?: FieldRole } = {
	consumed: encodedAs("row K"),
	floor: encodedAs("row K"),
	floors: encodedAs("row K"),
};

export const CHECKER_ERROR_FIELD_ROLES: { [K in keyof CheckerError]-?: FieldRole } = {
	message: encodedAs("error row !"),
	line: encodedAs("error row !"),
	column: encodedAs("error row !"),
	endLine: encodedAs("error row !"),
	endColumn: encodedAs("error row !"),
	fatal: encodedAs("error row !"),
	severity: encodedAs("error row !"),
	tags: encodedAs("error row !"),
};

export const CHECKED_INSTANTIATION_FIELD_ROLES: { [K in keyof CheckedInstantiation]-?: FieldRole } = {
	sym: encodedAs("rows O/P"),
	params: encodedAs("rows O/P"),
	concreteTypes: encodedAs("rows O/P"),
};

export const MACRO_CONVERTER_FIELD_ROLES: { [K in keyof MacroConverter]-?: FieldRole } = {
	sym: encodedAs("row k"),
	tier: encodedAs("row k"),
};

export const JS_IMPORT_ENTRY_FIELD_ROLES: { [K in keyof JsImportEntry]-?: FieldRole } = {
	modulePath: encodedAs("row @"),
	names: encodedAs("row @"),
};

export const LOCKED_MOVE_FIELD_ROLES: { [K in keyof LockedMove]-?: FieldRole } = {
	move: encodedAs("row 4"),
	routine: encodedAs("row 4"),
};

let _toolStampFn: (() => string) | null = null;

export function registerStdUnitStamps(tool: () => string): void {
	_toolStampFn = tool;
}

export function stdUnitRequested(): boolean {
	return env.get("MSC_NO_STD_UNIT") != "1";
}

function unitBase(): string {
	const root = globalCacheRoot();
	return root == "" ? "" : `${root}/stdunit`;
}

function unitDir(): string {
	const base = unitBase();
	return base == "" ? "" : `${base}/${STD_UNIT_MAGIC}`;
}

export function stdUnitStoreOff(): boolean {
	return unitDir() == "";
}

let _state = "off";
let _keyMs: float64 = 0;
let _loadMs: float64 = 0;
let _writeMs: float64 = 0;
let _bytes: int64 = 0;
const _reasons: Map<string, int32> = new Map<string, int32>();

function note(state: string, reason: string): void {
	_state = state;
	if (reason == "") return;
	const label = `${state}: ${reason}`;
	_reasons.set(label, (_reasons.get(label) ?? 0) + 1);
}

export function noteStdUnitRefused(reason: string): void {
	note("refused", reason);
}

export function stdUnitReport(): string {
	let out = `state=${_state} key=${_keyMs}ms load=${_loadMs}ms write=${_writeMs}ms bytes=${_bytes}`;
	for (const [label, count] of _reasons) out = `${out} [${label}]x${count}`;
	return out;
}

export function stdUnitTimeKey(started: float64): void {
	_keyMs = _keyMs + (performance.now() - started);
}

let _graphChecks: int32 = 0;

export function noteGraphCheck(): void {
	_graphChecks += 1;
}

export function processFreshness(): string {
	if (_graphChecks > 0) return "this process ran an earlier graph check";
	if (maybeCacheSize() != 0) return "the Maybe cache is not empty";
	if (duVariantMark() != 0) return "the union variant registry is not empty";
	if (opMark() != 0) return "the type-bound op table is not empty";
	if (linkFlags().size != 0 || linkObjects().size != 0) return "the link state is not empty";
	if (moduleItemPaths().length != 0) return "module item ids were interned";
	const defaults = defaultsRows();
	if (defaults.checked.length != 0 || defaults.stored.length != 0) return "default-argument tables are not empty";
	const hooks = instanceHookRows();
	if (hooks.owners.length != 0 || hooks.scannedOwners.length != 0 || hooks.typedOwners.length != 0) return "instance hook tables are not empty";
	const held = heldBeyondRows();
	if (held.syms.length != 0 || held.slots.length != 0) return "held-beyond tables are not empty";
	if (effectsCheckedModules().length != 0) return "the effect checker saw a module";
	if (registeredModuleCount() != 0) return "module contexts are registered";
	if (localGenericCount() != 0) return "a local generic is declared";
	if (forwardTablesPending() != 0) return "forward type tables are not empty";
	if (checksInFlight() != 0) return "a routine, field or block check is in flight";
	return "";
}

export function engineMark(): string {
	return `${macroPreprocessCount()}/${macroCompileCount()}/${engineCompiledNames().length}/${comptimeRunCount()}`;
}

export function stdUnitKeyText(graph: ModuleGraph, config: ResolverConfig, targetOs: string, targetInfo: TargetInfo, gcMode: GcMode, strictNullChecks: boolean, appMode: string): string {
	const toolFn = _toolStampFn;
	if (toolFn == null || config.stdPath == "") return "";
	const runtimeRoot = resolveRuntimeDir();
	const roots = buildModuleNameRoots();
	const modules: string[] = [];
	for (const path of graph.loadOrder) {
		const mod = findModule(graph, path);
		if (mod == null || !mod.stdPrelude) continue;
		modules.push(`${path}=${rootedModuleKey(roots, path)}#${hashContent(mod.rawSource)}`);
	}
	const parts: string[] = [
		STD_UNIT_MAGIC,
		`tool=${toolFn()}`,
		`stdPath=${config.stdPath}`,
		`backend=${config.backend as int32}`,
		`extensions=${config.extensions.join(",")}`,
		`searchPaths=${config.searchPaths.join(",")}`,
		`aliases=${config.aliasKeys.join(",")}=${config.aliasValues.join(",")}`,
		`os=${targetOs}`,
		`target=${targetInfo.ptrSize},${targetInfo.floatSize},${targetInfo.cpu},${targetInfo.os}`,
		`gc=${gcMode as int32}`,
		`strictNull=${strictNullChecks ? 1 : 0}`,
		`app=${appMode}`,
		`defines=${defineIdentity(getParserDefines())}`,
		`imports=${defaultGlobalImports().join(",")}`,
		`extra=${extraGlobalImports().join(",")}`,
		`passes=${modulePassIdentity()}`,
		`roots=${roots.compiler},${roots.packages}`,
		`runtime=${runtimeRoot}`,
		`modules=${modules.join(",")}`,
	];
	return parts.join("\n");
}

function unitPath(keyText: string): string {
	const dir = unitDir();
	return dir == "" ? "" : `${dir}/${hashContent(keyText)}.su`;
}

function unitHeader(keyText: string): string {
	return `${STD_UNIT_MAGIC}\nK\t${escapeP(keyText)}\n`;
}

export function collectUnusedStdUnits(now: float64): void {
	const base = unitBase();
	if (base != "") collectStaleEntries(base, now, [".su"], STD_UNIT_UNUSED_SECONDS);
}

function publish(path: string, content: string): boolean {
	const dir = path.slice(0, path.lastIndexOf("/"));
	const tmp = `${path}.tmp.${performance.now()}.${Math.floor(Math.random() * 1000000000)}`;
	if (!writeFile(tmp, content).ok) {
		ensureDir(dir);
		if (!writeFile(tmp, content).ok) return false;
	}
	if (rename(tmp, path).ok) return true;
	remove(tmp);
	return false;
}

export class StdUnitModule {
	path: string = "";
	ctx: CheckerContext = null as unknown as CheckerContext;
	program: Node = null as unknown as Node;
	exportNames: string[] = [];
	record: TaCheckRecord = new TaCheckRecord();
}

export class StdUnitInput {
	keyText: string = "";
	engineMark: string = "";
	db: TransAmDb;
	graph: ModuleGraph;
	base: CheckerContext;
	modules: StdUnitModule[] = [];

	constructor(db: TransAmDb, graph: ModuleGraph, base: CheckerContext) {
		this.db = db;
		this.graph = graph;
		this.base = base;
	}
}

class UnitOut {
	w: RowWriter = new RowWriter();
	emitting: boolean = false;
	lines: string[] = [];
	cols: string[] = [];
	problem: string = "";
	ctxs: CheckerContext[] = [];
	ctxIdx: HashMap<CheckerContext, int32> = new HashMap<CheckerContext, int32>();
	regs: ExtensionRegistry[] = [];
	regIdx: HashMap<ExtensionRegistry, int32> = new HashMap<ExtensionRegistry, int32>();
	exts: ExtensionMethod[] = [];
	extIdx: HashMap<ExtensionMethod, int32> = new HashMap<ExtensionMethod, int32>();
}

function fail(this o: UnitOut, why: string): void {
	if (o.problem == "") o.problem = why;
}

function begin(this o: UnitOut, tag: string): void {
	o.cols = [tag];
}

function end(this o: UnitOut): void {
	if (o.emitting) o.lines.push(o.cols.join("\t"));
}

function putInt(this o: UnitOut, v: int64): void {
	if (o.emitting) o.cols.push(`${v}`);
}

function putNumber(this o: UnitOut, v: number): void {
	if (Math.trunc(v) != v) o.fail(`a counter holds the fraction ${v}`);
	o.putInt(v as int64);
}

function putBool(this o: UnitOut, b: boolean): void {
	o.putInt(b ? 1 : 0);
}

function putText(this o: UnitOut, s: string): void {
	if (o.emitting) o.cols.push(escapeP(s));
}

function putTexts(this o: UnitOut, items: string[]): void {
	o.putInt(items.length);
	for (const s of items) o.putText(s);
}

function putIntList(this o: UnitOut, items: int32[]): void {
	if (o.emitting) o.cols.push(intsCsv(items));
}

function symRef(o: UnitOut, s: Symbol | null): int32 {
	if (s == null) return -1;
	const i = o.w.idxSym(s);
	if (i < 0) o.fail(`symbol '${s.name}' of ${s.modulePath} is outside the unit`);
	return i;
}

function typeRef(o: UnitOut, t: Type | null): int32 {
	if (t == null) return -1;
	const i = o.w.idxType(t);
	if (i < 0) o.fail(`a type '${t.typeName}' is outside the unit`);
	return i;
}

function nodeRef(o: UnitOut, n: Node | null): int32 {
	if (n == null) return -1;
	const i = o.w.idxNode(n);
	if (i < 0) o.fail(`a node of kind ${n.kind as int32} is outside the unit`);
	return i;
}

function putSym(this o: UnitOut, s: Symbol | null): void {
	if (!o.emitting) {
		o.w.enqSym(s, false);
		return;
	}
	o.cols.push(`${symRef(o, s)}`);
}

function putType(this o: UnitOut, t: Type | null): void {
	if (!o.emitting) {
		o.w.enqType(t);
		return;
	}
	o.cols.push(`${typeRef(o, t)}`);
}

function putNode(this o: UnitOut, n: Node | null): void {
	if (!o.emitting) {
		o.w.enqNode(n);
		return;
	}
	o.cols.push(`${nodeRef(o, n)}`);
}

function putSyms(this o: UnitOut, items: Symbol[]): void {
	if (!o.emitting) {
		for (const s of items) o.w.enqSym(s, false);
		return;
	}
	const idx: int32[] = [];
	for (const s of items) idx.push(symRef(o, s));
	o.cols.push(intsCsv(idx));
}

function putTypes(this o: UnitOut, items: Type[]): void {
	if (!o.emitting) {
		for (const t of items) o.w.enqType(t);
		return;
	}
	const idx: int32[] = [];
	for (const t of items) idx.push(typeRef(o, t));
	o.cols.push(intsCsv(idx));
}

function putNodes(this o: UnitOut, items: Node[]): void {
	if (!o.emitting) {
		for (const n of items) o.w.enqNode(n);
		return;
	}
	const idx: int32[] = [];
	for (const n of items) idx.push(nodeRef(o, n));
	o.cols.push(intsCsv(idx));
}

function putCtx(this o: UnitOut, ctx: CheckerContext | null): void {
	if (ctx == null) {
		o.putInt(-1);
		return;
	}
	const i = o.ctxIdx.get(ctx);
	if (i == null) {
		o.fail("a context field names a context outside the unit");
		o.putInt(-1);
		return;
	}
	o.putInt(i);
}

function regRef(o: UnitOut, r: ExtensionRegistry | null): int32 {
	if (r == null) return -1;
	const i = o.regIdx.get(r);
	if (i == null) {
		o.fail("an extension registry outside the unit");
		return -1;
	}
	return i;
}

function extRef(o: UnitOut, m: ExtensionMethod | null): int32 {
	if (m == null) return -1;
	const i = o.extIdx.get(m);
	if (i == null) {
		o.fail(`extension '${m.methodName}' is outside the unit`);
		return -1;
	}
	return i;
}

function symSortKey(s: Symbol): string {
	const loc = s.location;
	return `${s.modulePath}\t${s.name}\t${loc !== null ? loc.line : 0}\t${loc !== null ? loc.column : 0}\t${s.symbolKind as int32}\t${s.itemModule}\t${s.item}\t${s.disamb}`;
}

function nodeSortKey(n: Node): string {
	const loc = n.location;
	return `${n.kind as int32}\t${loc.line}\t${loc.column}\t${loc.endLine}\t${loc.endColumn}`;
}

function textOrder(keys: string[]): int32[] {
	const order: int32[] = [];
	for (let i = 0; i < keys.length; i += 1) order.push(i as int32);
	order.sort((a: int32, b: int32): number => keys[a] < keys[b] ? -1 : keys[a] > keys[b] ? 1 : a - b);
	return order;
}

function indexOrder(keys: int32[]): int32[] {
	const order: int32[] = [];
	for (let i = 0; i < keys.length; i += 1) order.push(i as int32);
	order.sort((a: int32, b: int32): number => keys[a] != keys[b] ? keys[a] - keys[b] : a - b);
	return order;
}

function symOrder(o: UnitOut, items: Symbol[]): int32[] {
	if (o.emitting) {
		const idx: int32[] = [];
		for (const s of items) idx.push(o.w.idxSym(s));
		return indexOrder(idx);
	}
	const keys: string[] = [];
	for (const s of items) keys.push(symSortKey(s));
	return textOrder(keys);
}

function nodeOrder(o: UnitOut, items: Node[]): int32[] {
	if (o.emitting) {
		const idx: int32[] = [];
		for (const n of items) idx.push(o.w.idxNode(n));
		return indexOrder(idx);
	}
	const keys: string[] = [];
	for (const n of items) keys.push(nodeSortKey(n));
	return textOrder(keys);
}

function sortedSyms(o: UnitOut, items: Symbol[]): Symbol[] {
	const out: Symbol[] = [];
	for (const k of symOrder(o, items)) out.push(items[k]);
	return out;
}

function sortedNodes(o: UnitOut, items: Node[]): Node[] {
	const out: Node[] = [];
	for (const k of nodeOrder(o, items)) out.push(items[k]);
	return out;
}

function sortedTexts(items: string[]): string[] {
	const out: string[] = [];
	for (const k of textOrder(items)) out.push(items[k]);
	return out;
}

function symsOfSet(set: HashSet<Symbol>): Symbol[] {
	const out: Symbol[] = [];
	for (const s of set) out.push(s);
	return out;
}

function nodesOfSet(set: HashSet<Node>): Node[] {
	const out: Node[] = [];
	for (const n of set) out.push(n);
	return out;
}

function textsOfSet(set: HashSet<string>): string[] {
	const out: string[] = [];
	for (const s of set) out.push(s);
	return out;
}

function symKeys<V>(map: HashMap<Symbol, V>): Symbol[] {
	const out: Symbol[] = [];
	for (const k of map.keys()) out.push(k);
	return out;
}

function nodeKeys<V>(map: HashMap<Node, V>): Node[] {
	const out: Node[] = [];
	for (const k of map.keys()) out.push(k);
	return out;
}

function addReg(o: UnitOut, r: ExtensionRegistry | null): void {
	if (r == null || o.regIdx.has(r)) return;
	o.regIdx.set(r, o.regs.length as int32);
	o.regs.push(r);
	addReg(o, r.base);
	addReg(o, r.exportLayer);
}

function addExt(o: UnitOut, m: ExtensionMethod | null): void {
	if (m == null || o.extIdx.has(m)) return;
	o.extIdx.set(m, o.exts.length as int32);
	o.exts.push(m);
}

function prepare(o: UnitOut, u: StdUnitInput): void {
	o.ctxs.push(u.base);
	for (const m of u.modules) o.ctxs.push(m.ctx);
	for (let i = 0; i < o.ctxs.length; i += 1) {
		if (o.ctxIdx.has(o.ctxs[i])) o.fail(`two prelude modules share one context`);
		o.ctxIdx.set(o.ctxs[i], i as int32);
	}
	for (const ctx of o.ctxs) addReg(o, ctx.extensionRegistry);
	for (let i = 0; i < o.regs.length; i += 1) {
		for (const m of o.regs[i].own) addExt(o, m);
	}
	for (const entry of u.db.exportRegistry.entries) {
		for (const info of entry.symbols) {
			addExt(o, info.ext);
			for (const m of info.overloadExts) addExt(o, m);
		}
	}
}

function putUnit(o: UnitOut, u: StdUnitInput): void {
	putGlobals(o, u);
	putDispatch(o, u.db.dispatchRegistry);
	putExtensions(o);
	putExports(o, u.db.exportRegistry);
	putModules(o, u);
	for (let i = 0; i < o.ctxs.length; i += 1) putContext(o, o.ctxs[i], i == 0, u);
	o.begin(".");
	o.end();
}

function putGlobals(o: UnitOut, u: StdUnitInput): void {
	o.begin("w");
	o.putTexts(u.base.table.identCache.names);
	o.end();
	o.begin("i");
	if (o.emitting) {
		const ids: int32[] = [];
		for (const s of o.w.syms) ids.push(s.nameId);
		o.cols.push(intsCsv(ids));
	}
	o.end();
	o.begin("m");
	o.putTexts(moduleItemPaths());
	o.end();
	o.begin("f");
	o.putTexts(sortedTexts(decodedRoutineFlagKeys()));
	o.end();
	o.begin("F");
	o.putTexts(sortedTexts(decodedRoutineFlagTextKeys()));
	o.end();
	const maybeKeys = maybeCacheKeys();
	const maybeTypes = maybeCacheTypes();
	o.begin("y");
	o.putInt(maybeKeys.length);
	for (let i = 0; i < maybeKeys.length; i += 1) {
		o.putText(maybeKeys[i]);
		o.putType(maybeTypes[i]);
	}
	o.end();
	o.begin("v");
	o.putTypes(duVariantsFrom(0));
	o.end();
	const defaults = defaultsRows();
	o.begin("d");
	o.putNodes(sortedNodes(o, defaults.checked));
	o.end();
	o.begin("D");
	o.putInt(defaults.stored.length);
	for (const k of nodeOrder(o, defaults.stored)) {
		o.putNode(defaults.stored[k]);
		o.putNode(defaults.sources[k]);
	}
	o.end();
	const hooks = instanceHookRows();
	o.begin("h");
	o.putInt(hooks.owners.length);
	o.end();
	for (const k of symOrder(o, hooks.owners)) {
		o.begin("H");
		o.putSym(hooks.owners[k]);
		o.putInt(hooks.ops[k] as int32);
		o.putSym(hooks.syms[k]);
		o.putTypes(hooks.concreteTypes[k]);
		o.end();
	}
	o.begin("c");
	o.putInt(hooks.scannedOwners.length);
	o.end();
	for (const k of symOrder(o, hooks.scannedOwners)) {
		o.begin("C");
		o.putSym(hooks.scannedOwners[k]);
		o.putTypes(hooks.scanned[k]);
		o.end();
	}
	o.begin("k");
	o.putInt(hooks.typedOwners.length);
	o.end();
	for (const k of symOrder(o, hooks.typedOwners)) {
		o.begin("K");
		o.putSym(hooks.typedOwners[k]);
		o.putTypes(hooks.typed[k]);
		o.end();
	}
	const held = heldBeyondRows();
	o.begin("b");
	o.putInt(held.syms.length);
	o.end();
	for (const k of symOrder(o, held.syms)) {
		o.begin("B");
		o.putSym(held.syms[k]);
		o.putTypes(held.symHeld[k]);
		o.end();
	}
	o.begin("q");
	o.putInt(held.slots.length);
	o.end();
	const slotKeys: string[] = [];
	for (let i = 0; i < held.slots.length; i += 1) slotKeys.push(`${held.fieldNames[i]}\t${o.emitting ? o.w.idxType(held.slots[i]) : 0}`);
	for (const k of textOrder(slotKeys)) {
		o.begin("Q");
		o.putText(held.fieldNames[k]);
		o.putType(held.slots[k]);
		o.putTypes(held.slotHeld[k]);
		o.end();
	}
	o.begin("e");
	o.putTexts(sortedTexts(effectsCheckedModules()));
	o.end();
	const ops = opsFrom(0);
	o.begin("o");
	o.putInt(ops.length);
	o.end();
	for (const op of ops) {
		o.begin("O");
		o.putText(op.key);
		o.putSym(op.sym);
		o.putBool(op.canon);
		o.end();
	}
	const canon = opCanonRows();
	o.begin("+");
	o.putInt(canon.syms.length);
	for (const k of symOrder(o, canon.syms)) {
		o.putSym(canon.syms[k]);
		o.putText(canon.keys[k]);
	}
	o.end();
	const flags: string[] = [];
	for (const flag of linkFlags()) flags.push(flag);
	const objects: string[] = [];
	for (const object of linkObjects()) objects.push(object);
	o.begin("l");
	o.putTexts(flags);
	o.end();
	o.begin("L");
	o.putTexts(objects);
	o.end();
	putWellKnown(o);
}

function putOptionalTexts(o: UnitOut, items: string[] | null): void {
	o.putBool(items != null);
	o.putTexts(items != null ? items : []);
}

function putWellKnown(o: UnitOut): void {
	const known = wellKnownTypes();
	o.begin("*");
	o.putInt(known.length);
	o.end();
	for (const t of known) {
		const ops: Symbol[] = [];
		for (const op of t.attachedOps) ops.push(op as Symbol);
		o.begin("^");
		o.putInt(t.kind as int32);
		o.putInt(t.typeFlags as uint32);
		o.putInt(t.typeValue);
		o.putInt(t.callConv as int32);
		o.putTypes(t.typeChildren != null ? t.typeChildren : []);
		o.putBool(t.typeChildren != null);
		o.putType(t.typeReturn);
		o.putType(t.typeExtra);
		o.putType(t.typeParamDefault);
		o.putSyms(ops);
		o.putSym(t.sym);
		o.putType(t.typeInst);
		o.putType(t.readonlyView);
		o.putType(t.mutableView);
		o.putType(t.ownedType);
		o.putType(t.plainType);
		o.putText(t.typeName);
		putOptionalTexts(o, t.typeNames);
		putOptionalTexts(o, t.optionalFields);
		o.end();
	}
}

function putDispatch(o: UnitOut, reg: DispatchRegistry): void {
	if (reg.capture != null || reg.readSink != null || reg.seeded.size != 0) o.fail("the dispatch registry captures, tracks reads or holds seeds");
	const entryIdx = new HashMap<DispMethodEntry, int32>();
	o.begin("r");
	o.putInt(reg.version);
	o.putInt(reg.entries.length);
	o.end();
	for (let i = 0; i < reg.entries.length; i += 1) {
		const e = reg.entries[i];
		entryIdx.set(e, i as int32);
		o.begin("R");
		o.putSym(e.classSym);
		o.putText(e.methodName);
		o.putSym(e.sym);
		o.putBool(e.overloaded);
		o.putInt(e.version);
		o.end();
	}
	const entryRef = (e: DispMethodEntry): int32 => {
		const i = entryIdx.get(e);
		if (i == null) {
			o.fail("a dispatch index names an entry the registry does not list");
			return -1;
		}
		return i;
	};
	const classes = symKeys(reg.byClass);
	o.begin("u");
	o.putInt(classes.length);
	o.end();
	for (const k of symOrder(o, classes)) {
		const list = reg.byClass.get(classes[k]) ?? [];
		const idx: int32[] = [];
		for (const e of list) idx.push(entryRef(e));
		o.begin("U");
		o.putSym(classes[k]);
		o.putIntList(idx);
		o.end();
	}
	const syms = symKeys(reg.bySym);
	o.begin("p");
	o.putInt(syms.length);
	o.end();
	for (const k of symOrder(o, syms)) {
		const e = reg.bySym.get(syms[k]);
		o.begin("P");
		o.putSym(syms[k]);
		o.putInt(e != null ? entryRef(e) : -1);
		o.end();
	}
}

function putExtensions(o: UnitOut): void {
	o.begin("x");
	o.putInt(o.exts.length);
	o.end();
	for (const m of o.exts) {
		o.begin("X");
		o.putText(m.methodName);
		o.putText(m.sourcePath);
		o.putBool(m.isStatic);
		o.putSym(m.sym);
		o.putNumber(m.scopeDepth);
		o.end();
	}
	o.begin("g");
	o.putInt(o.regs.length);
	o.end();
	for (const r of o.regs) {
		const own: int32[] = [];
		for (const m of r.own) own.push(extRef(o, m));
		o.begin("G");
		o.putInt(regRef(o, r.base));
		o.putInt(r.baseCount);
		o.putBool(r.sealed);
		o.putInt(r.truncations);
		o.putInt(regRef(o, r.exportLayer));
		o.putInt(r.sourceSeen);
		o.putInt(r.sourceTruncations);
		o.putIntList(own);
		o.end();
	}
}

function putExports(o: UnitOut, reg: ExportRegistry): void {
	o.begin("z");
	o.putInt(reg.entries.length);
	o.end();
	for (let i = 0; i < reg.entries.length; i += 1) {
		const entry = reg.entries[i];
		if ((reg.moduleIndex.get(entry.modulePath) ?? -1) != i) o.fail(`the export registry indexes ${entry.modulePath} at another entry`);
		o.begin("Z");
		o.putText(entry.modulePath);
		o.putInt(entry.symbols.length);
		o.end();
		for (const info of entry.symbols) {
			const overloads: int32[] = [];
			for (const m of info.overloadExts) overloads.push(extRef(o, m));
			o.begin("Y");
			o.putText(info.name);
			o.putSym(info.sym);
			o.putInt(extRef(o, info.ext));
			o.putIntList(overloads);
			o.putType(info.converterTargetType);
			o.end();
		}
	}
	o.begin("a");
	o.putInt(reg.cTags.size as int32);
	for (const [name, sym] of reg.cTags) {
		o.putText(name);
		o.putSym(sym);
	}
	o.end();
}

function putModules(o: UnitOut, u: StdUnitInput): void {
	o.begin("n");
	o.putInt(u.modules.length);
	o.end();
	for (const m of u.modules) {
		const kinds: int32[] = [];
		for (const kind of m.record.kinds) kinds.push(kind as int32);
		o.begin("M");
		o.putText(m.path);
		o.putNode(m.program);
		o.putInt(m.record.durability as int32);
		o.putBool(m.record.collected);
		o.putIntList(kinds);
		o.putTexts(m.exportNames);
		o.putTexts(m.record.paths);
		o.end();
	}
}

function carriedScopes(o: UnitOut, ctx: CheckerContext): Scope[] {
	const keep = new HashSet<Scope>();
	const chains: (Scope | null)[] = [ctx.table.current, ctx.readonlyBoundary, ctx.staticInitBoundary, ctx.hookBodyBoundary];
	for (const scope of ctx.table.allScopes) {
		if (scope.scopeKind == ScopeKind.Global || scope.scopeKind == ScopeKind.Module) chains.push(scope);
	}
	for (const start of chains) {
		let scope: Scope | null = start;
		while (scope != null && !keep.has(scope)) {
			keep.add(scope);
			scope = scope.parent;
		}
	}
	const out: Scope[] = [];
	for (const scope of ctx.table.allScopes) {
		if (keep.has(scope)) out.push(scope);
	}
	if (out.length != keep.size) o.fail(`${ctx.modulePath} holds a scope outside its table`);
	return out;
}

function scopeRef(o: UnitOut, index: HashMap<Scope, int32>, scope: Scope | null): int32 {
	if (scope == null) return -1;
	const i = index.get(scope);
	if (i == null) {
		o.fail("a scope reference outside the carried scopes");
		return -1;
	}
	return i;
}

function putTextLists(o: UnitOut, rows: string[][] | null): void {
	o.putBool(rows != null);
	if (rows == null) return;
	o.putInt(rows.length);
	for (const row of rows) o.putTexts(row);
}

function putContext(o: UnitOut, ctx: CheckerContext, isBase: boolean, u: StdUnitInput): void {
	if (ctx.preludeDispatchRecords != null) o.fail(`${ctx.modulePath} holds prelude dispatch records`);
	if (ctx.globalImportsCtx != null) o.fail(`${ctx.modulePath} reads a build.ms global import layer`);
	if (ctx.dispatchRegistry != u.db.dispatchRegistry) o.fail(`${ctx.modulePath} records dispatch outside the db`);
	if (ctx.table.identCache != u.base.table.identCache) o.fail(`${ctx.modulePath} interns names outside the base's cache`);
	if (isBase) {
		if (ctx.preludeCtx != null) o.fail("the base context has a prelude of its own");
		if (ctx.exportRegistry.entries.length != 0) o.fail("the base context registered exports of its own");
	} else {
		const mod = findModule(u.graph, ctx.modulePath);
		if (ctx.preludeCtx != u.base) o.fail(`${ctx.modulePath} reads another prelude`);
		if (ctx.compilerFuncs != u.base.compilerFuncs) o.fail(`${ctx.modulePath} does not share the base's compiler functions`);
		if (ctx.exportRegistry != u.db.exportRegistry) o.fail(`${ctx.modulePath} registers exports outside the db`);
		if (ctx.moduleGraph != u.graph || mod == null || ctx.currentModule != mod) o.fail(`${ctx.modulePath} was checked against another graph`);
		if (ctx.cancelCtx != u.db.cancelCtx) o.fail(`${ctx.modulePath} was checked under another cancel context`);
		const target = ctx.targetInfo;
		const stamped = u.base.targetInfo;
		if (target.ptrSize != stamped.ptrSize || target.floatSize != stamped.floatSize || target.cpu != stamped.cpu || target.os != stamped.os) o.fail(`${ctx.modulePath} was checked for another target`);
	}
	o.begin("0");
	o.putInt(ctx.gcMode as int32);
	o.putText(ctx.targetOs);
	o.putText(ctx.appMode);
	o.putText(ctx.stdRoot);
	o.putBool(ctx.strictNullChecks);
	o.putInt(ctx.typeTestDepth);
	o.putBool(ctx.inLoop);
	o.putBool(ctx.inSwitch);
	o.putBool(ctx.decoratorsPending);
	o.putBool(ctx.inTestBlock);
	o.putBool(ctx.pendingSpawnThunk);
	o.putInt(ctx.macroExpansionDepth);
	o.putInt(ctx.jsxMacroArgDepth);
	o.putBool(ctx.symRecordsOff);
	o.putNumber(ctx.compileTimeBodyDepth);
	o.putBool(ctx.inTryExpr);
	o.putInt(ctx.genericInstDepth);
	o.putInt(ctx.condEvalDepth);
	o.putInt(ctx.inGenericContext);
	o.putInt(ctx.itemModule);
	o.putInt(ctx.nextItem);
	o.putInt(ctx.cancelVersion);
	o.putText(ctx.modulePath);
	o.putText(ctx.includeDirectives);
	o.putText(ctx.compileDirectives);
	o.putText(ctx.compilerFlags);
	o.end();
	o.begin("1");
	o.putSym(ctx.currentFunction);
	o.putSym(ctx.currentActor);
	o.putSym(ctx.staticBlockClass);
	o.putSym(ctx.jsxConsumer);
	o.putSym(ctx.tryGuardedFunction);
	o.putNode(ctx.refillTarget);
	o.putNode(ctx.refillValue);
	o.putNode(ctx.awaitedCall);
	o.putNode(ctx.topProgram);
	o.putNode(ctx.stmtPosExpr);
	o.putNode(ctx.typeExprSlot);
	o.putNode(ctx.calleeExpr);
	o.putNode(ctx.conversionOperand);
	o.putType(ctx.awaitedPayload);
	o.putType(ctx.inferredReturn);
	o.putType(ctx.matchArmExpected);
	o.putType(ctx.conversionTarget);
	o.putCtx(ctx.instantiatingCtx);
	o.putInt(regRef(o, ctx.extensionRegistry));
	o.end();
	o.begin("2");
	o.putNodes(ctx.staticBlockPending);
	o.putNodes(ctx.identifierMoves);
	o.putNodes(ctx.computedGotoMarks);
	o.putNodes(ctx.inferredReturnStmts);
	o.putNodes(ctx.inferredReturnTries);
	o.putNodes(ctx.armTails);
	o.putNodes(ctx.pendingHoisted);
	o.putNodes(ctx.pendingTrailing);
	o.putNodes(ctx.generatedInstances);
	o.putNodes(ctx.pendingLocalTypeDecls);
	o.putNodes(ctx.liftedLocalTypeDecls);
	o.end();
	o.begin("3");
	o.putTexts(ctx.instantiationSites);
	o.end();
	o.begin("4");
	o.putInt(ctx.lockedMoves.length);
	for (const lock of ctx.lockedMoves) {
		o.putNode(lock.move);
		o.putNode(lock.routine);
	}
	o.end();
	o.begin("5");
	putTextLists(o, ctx.ctorExits);
	o.end();
	o.begin("6");
	putTextLists(o, ctx.ctorExitsNext);
	o.end();
	const scopes = carriedScopes(o, ctx);
	const scopeIdx = new HashMap<Scope, int32>();
	for (let i = 0; i < scopes.length; i += 1) scopeIdx.set(scopes[i], i as int32);
	o.begin("7");
	o.putInt(scopes.length);
	o.putInt(scopeRef(o, scopeIdx, ctx.table.current));
	o.putInt(scopeRef(o, scopeIdx, ctx.readonlyBoundary));
	o.putInt(scopeRef(o, scopeIdx, ctx.staticInitBoundary));
	o.putInt(scopeRef(o, scopeIdx, ctx.hookBodyBoundary));
	o.end();
	for (let i = 0; i < scopes.length; i += 1) {
		const scope = scopes[i];
		const parent = scopeRef(o, scopeIdx, scope.parent);
		if (parent >= i) o.fail("a carried scope's parent comes after it");
		const keys: int32[] = [];
		const members: Symbol[] = [];
		for (const [id, sym] of scope.symbols) {
			keys.push(id);
			members.push(sym);
		}
		o.begin("8");
		o.putInt(scope.scopeKind as int32);
		o.putInt(parent);
		o.putSym(scope.privateAccess);
		o.putIntList(keys);
		o.putSyms(members);
		o.putTexts(scope.friendModules);
		o.end();
	}
	o.begin("9");
	o.putInt(ctx.errors.length);
	o.end();
	for (const err of ctx.errors) {
		o.begin("!");
		o.putText(err.message);
		o.putInt(err.line);
		o.putInt(err.column);
		o.putInt(err.endLine);
		o.putInt(err.endColumn);
		o.putBool(err.fatal);
		o.putInt(err.severity as int32);
		o.putNumber(err.tags);
		o.end();
	}
	o.begin("j");
	o.putSyms(sortedSyms(o, symsOfSet(ctx.capturedSyms)));
	o.end();
	o.begin("k");
	o.putInt(ctx.macroConverters.length);
	for (const conv of ctx.macroConverters) {
		o.putSym(conv.sym);
		o.putInt(conv.tier);
	}
	o.end();
	const converters = symKeys(ctx.converterTargetTypes);
	o.begin("l");
	o.putInt(converters.length);
	for (const k of symOrder(o, converters)) {
		o.putSym(converters[k]);
		o.putType(ctx.converterTargetTypes.get(converters[k]));
	}
	o.end();
	o.begin("m");
	o.putSyms(ctx.runtimeConverters);
	o.end();
	o.begin("n");
	o.putInt(ctx.jsImportRegistry.length);
	o.end();
	for (const entry of ctx.jsImportRegistry) {
		o.begin("@");
		o.putText(entry.modulePath);
		o.putTexts(entry.names);
		o.end();
	}
	putInstCache(o, "o", "O", ctx.procInstCache);
	putInstCache(o, "p", "P", ctx.typeInstCache);
	o.begin("q");
	o.putInt(ctx.disambTable.size as int32);
	for (const [name, count] of ctx.disambTable) {
		o.putText(name);
		o.putInt(count);
	}
	o.end();
	const after = ctx.disambAfterCheck;
	o.begin("r");
	o.putBool(after != null);
	if (after != null) {
		o.putInt(after.size as int32);
		for (const [name, count] of after) {
			o.putText(name);
			o.putInt(count);
		}
	}
	o.end();
	o.begin("s");
	o.putInt(ctx.localTypeNames.size as int32);
	for (const [name, local] of ctx.localTypeNames) {
		o.putText(name);
		o.putBool(local);
	}
	o.end();
	o.begin("t");
	o.putSyms(ctx.interf);
	o.end();
	o.begin("u");
	o.putSyms(sortedSyms(o, symsOfSet(ctx.interfSet)));
	o.end();
	const named = symKeys(ctx.interfNames);
	o.begin("v");
	o.putInt(named.length);
	o.end();
	for (const k of symOrder(o, named)) {
		o.begin("V");
		o.putSym(named[k]);
		o.putTexts(ctx.interfNames.get(named[k]) ?? []);
		o.end();
	}
	o.begin("x");
	o.putTexts(sortedTexts(textsOfSet(ctx.explicitExportNames)));
	o.end();
	o.begin("y");
	o.putSyms(sortedSyms(o, symsOfSet(ctx.importSet)));
	o.end();
	o.begin("z");
	o.putSyms(sortedSyms(o, symsOfSet(ctx.usedImports)));
	o.end();
	const shadowed = symKeys(ctx.shadowedImports);
	o.begin("A");
	o.putInt(shadowed.length);
	for (const k of symOrder(o, shadowed)) {
		o.putSym(shadowed[k]);
		o.putSym(ctx.shadowedImports.get(shadowed[k]));
	}
	o.end();
	o.begin("B");
	o.putInt(ctx.preludeInterf.size as int32);
	o.end();
	for (const [spec, members] of ctx.preludeInterf) {
		let owner: int32 = -1;
		for (let i = 0; i < o.ctxs.length; i += 1) {
			if (o.ctxs[i].interf == members) owner = i as int32;
		}
		o.begin("b");
		o.putText(spec);
		o.putInt(owner);
		o.putSyms(members);
		o.end();
	}
	o.begin("C");
	o.putSyms(sortedSyms(o, symsOfSet(ctx.preludeExports)));
	o.end();
	o.begin("D");
	o.putInt(ctx.preludeModuleScopes.size as int32);
	o.end();
	for (const [path, members] of ctx.preludeModuleScopes) {
		o.begin("d");
		o.putText(path);
		o.putSyms(members);
		o.end();
	}
	o.begin("E");
	o.putTexts(sortedTexts(textsOfSet(ctx.ownModules)));
	o.end();
	o.begin("F");
	if (isBase) {
		o.putInt(ctx.compilerFuncs.size as int32);
		for (const [name, sym] of ctx.compilerFuncs) {
			o.putText(name);
			o.putSym(sym);
		}
	} else {
		o.putInt(0);
	}
	o.end();
	const tracker = ctx.initTracker;
	const blocks: int32[] = [];
	for (const block of tracker.declBlocks) {
		if (Math.trunc(block) != block) o.fail(`a declaration block depth holds the fraction ${block}`);
		blocks.push(block as int32);
	}
	o.begin("J");
	o.putNumber(tracker.currentBlock);
	o.putNumber(tracker.leftPartOfAsgn);
	o.putNode(tracker.assignTarget);
	o.putNode(tracker.definiteTarget);
	o.putNodes(tracker.argIdents);
	o.putNodes(tracker.pendingReads);
	o.putIntList(blocks);
	o.putTexts(tracker.initialized);
	o.putTexts(tracker.declScopes);
	o.putTexts(tracker.outParams);
	o.end();
	o.begin("K");
	o.putInt(ctx.affineTracker.floor);
	o.putIntList(ctx.affineTracker.floors);
	o.putTexts(ctx.affineTracker.consumed);
	o.end();
	const adopted = nodeKeys(ctx.adoptedDecls);
	o.begin("L");
	o.putInt(adopted.length);
	for (const k of nodeOrder(o, adopted)) {
		o.putNode(adopted[k]);
		o.putSym(ctx.adoptedDecls.get(adopted[k]));
	}
	o.end();
	const params = nodeKeys(ctx.adoptedParams);
	o.begin("M");
	o.putInt(params.length);
	for (const k of nodeOrder(o, params)) {
		o.putNode(params[k]);
		o.putSyms(ctx.adoptedParams.get(params[k]) ?? []);
	}
	o.end();
	const bound = nodeKeys(ctx.boundIdents);
	o.begin("I");
	o.putInt(bound.length);
	for (const k of nodeOrder(o, bound)) {
		o.putNode(bound[k]);
		o.putSym(ctx.boundIdents.get(bound[k]));
	}
	o.end();
	const needs = nodeKeys(ctx.inferredNeeds);
	o.begin("W");
	o.putInt(needs.length);
	for (const k of nodeOrder(o, needs)) {
		o.putNode(needs[k]);
		o.putNodes(ctx.inferredNeeds.get(needs[k]) ?? []);
	}
	o.end();
	const owners = nodeKeys(ctx.inferredOwners);
	o.begin("X");
	o.putInt(owners.length);
	for (const k of nodeOrder(o, owners)) {
		o.putNode(owners[k]);
		o.putNode(ctx.inferredOwners.get(owners[k]));
	}
	o.end();
	const friends = nodeKeys(ctx.expansionFriends);
	o.begin("Y");
	o.putInt(friends.length);
	o.end();
	for (const k of nodeOrder(o, friends)) {
		o.begin("y");
		o.putNode(friends[k]);
		o.putTexts(ctx.expansionFriends.get(friends[k]) ?? []);
		o.end();
	}
	o.begin("Z");
	o.putNodes(sortedNodes(o, nodesOfSet(ctx.constContext)));
	o.end();
}

function putInstCache(o: UnitOut, headTag: string, rowTag: string, cache: HashMap<Symbol, CheckedInstantiation[]>): void {
	const keys = symKeys(cache);
	o.begin(headTag);
	o.putInt(keys.length);
	o.end();
	for (const k of symOrder(o, keys)) {
		const insts = cache.get(keys[k]) ?? [];
		o.begin(rowTag);
		o.putSym(keys[k]);
		o.putInt(insts.length);
		for (const inst of insts) {
			o.putSym(inst.sym);
			o.putTypes(inst.params);
			o.putTypes(inst.concreteTypes);
		}
		o.end();
	}
}

export function writeStdUnit(u: StdUnitInput): string {
	const started = performance.now();
	const path = unitPath(u.keyText);
	if (path == "") return "the global cache is off";
	const blocker = dbStdUnitBlocker(u.db);
	if (blocker != "") return blocker;
	if (!effectsAtRestAfter(u.graph)) return "the effect checker holds deferred work";
	if (!opTablesAtRest()) return "type-bound ops are written to a module table";
	if (localGenericCount() != 0) return "a local generic was never released";
	if (forwardTablesPending() != 0) return "forward type tables hold entries";
	if (checksInFlight() != 0) return "a routine, field or block check is still in flight";
	if (engineMark() != u.engineMark) return "the compile-time engine ran during the prelude";
	const o = new UnitOut();
	let blob = "";
	try {
		prepare(o, u);
		putUnit(o, u);
		o.w.closeOver();
		o.emitting = true;
		o.lines = [STD_UNIT_MAGIC, `K\t${escapeP(u.keyText)}`];
		o.w.emitObjectRows(o.lines);
		putUnit(o, u);
		if (o.problem == "") blob = o.lines.join("\n");
	} catch (e) {
		o.fail(`the writer threw: ${(e as Error).message}`);
	}
	if (o.problem != "") {
		_writeMs = _writeMs + (performance.now() - started);
		return o.problem;
	}
	ensureDir(unitDir());
	const written = publish(path, blob);
	collectUnusedStdUnits(nowSeconds());
	_writeMs = _writeMs + (performance.now() - started);
	if (!written) return "the unit could not be published";
	_bytes = blob.byteLength as int64;
	note("written", "");
	return "";
}

class InterfAlias {
	holder: CheckerContext = null as unknown as CheckerContext;
	spec: string = "";
	owner: int64 = -1;
	members: Symbol[] = [];
}

class UnitIn {
	aliases: InterfAlias[] = [];
	rd: PackReader;
	objs: RowReader = new RowReader();
	problem: string = "";
	peeked: int32 = -1;
	ctxs: CheckerContext[] = [];
	regs: ExtensionRegistry[] = [];
	exts: ExtensionMethod[] = [];

	constructor(body: string) {
		this.rd = new PackReader(body);
	}
}

function miss(this u: UnitIn, why: string): void {
	if (u.problem == "") u.problem = why;
}

function row(this u: UnitIn, tag: string): boolean {
	let got = u.peeked;
	u.peeked = -1;
	if (got < 0) got = u.rd.startRow();
	if (got != tag.charCodeAt(0)) {
		u.miss(`row '${tag}' expected`);
		return false;
	}
	return true;
}

function close(this u: UnitIn): void {
	if (u.rd.last == 9) u.miss("a row holds more fields than its reader takes");
	if (u.rd.bad) u.miss("a malformed field");
}

function getInt(this u: UnitIn): int64 {
	return u.rd.int();
}

function getI32(this u: UnitIn): int32 {
	const v = u.rd.int();
	if (v < -2147483648 || v > 2147483647) u.miss(`${v} is outside int32`);
	return v as int32;
}

function getCount(this u: UnitIn): int32 {
	const v = u.rd.int();
	if (v < 0 || v > MAX_ROW_COUNT) {
		u.miss(`a count of ${v}`);
		return 0;
	}
	return v as int32;
}

function getBool(this u: UnitIn): boolean {
	const v = u.rd.int();
	if (v != 0 && v != 1) u.miss(`a flag of ${v}`);
	return v == 1;
}

function getText(this u: UnitIn): string {
	return unescapeP(u.rd.str());
}

function getTexts(this u: UnitIn): string[] {
	const n = u.getCount();
	const out: string[] = [];
	for (let i = 0; i < n && u.problem == ""; i += 1) out.push(u.getText());
	return out;
}

function getIntList(this u: UnitIn): int32[] {
	return u.rd.ints();
}

function symAt(u: UnitIn, k: int64): Symbol | null {
	if (k == -1) return null;
	if (k < 0 || k >= u.objs.syms.length) {
		u.miss(`symbol ${k} is outside the unit`);
		return null;
	}
	return u.objs.syms[k as int32];
}

function typeAt(u: UnitIn, k: int64): Type | null {
	if (k == -1) return null;
	if (k < 0 || k >= u.objs.types.length) {
		u.miss(`type ${k} is outside the unit`);
		return null;
	}
	return u.objs.types[k as int32];
}

function nodeAt(u: UnitIn, k: int64): Node | null {
	if (k == -1) return null;
	if (k < 0 || k >= u.objs.nodes.length) {
		u.miss(`node ${k} is outside the unit`);
		return null;
	}
	return u.objs.nodes[k as int32];
}

function getSym(this u: UnitIn): Symbol | null {
	return symAt(u, u.rd.int());
}

function getType(this u: UnitIn): Type | null {
	return typeAt(u, u.rd.int());
}

function getNode(this u: UnitIn): Node | null {
	return nodeAt(u, u.rd.int());
}

function getSyms(this u: UnitIn): Symbol[] {
	const out: Symbol[] = [];
	for (const k of u.rd.ints()) out.push(symAt(u, k) as Symbol);
	return out;
}

function getTypes(this u: UnitIn): Type[] {
	const out: Type[] = [];
	for (const k of u.rd.ints()) out.push(typeAt(u, k) as Type);
	return out;
}

function getNodes(this u: UnitIn): Node[] {
	const out: Node[] = [];
	for (const k of u.rd.ints()) out.push(nodeAt(u, k) as Node);
	return out;
}

function getCtx(this u: UnitIn): CheckerContext | null {
	const k = u.rd.int();
	if (k == -1) return null;
	if (k < 0 || k >= u.ctxs.length) {
		u.miss(`context ${k} is outside the unit`);
		return null;
	}
	return u.ctxs[k as int32];
}

function regAt(u: UnitIn, k: int64): ExtensionRegistry | null {
	if (k == -1) return null;
	if (k < 0 || k >= u.regs.length) {
		u.miss(`registry ${k} is outside the unit`);
		return null;
	}
	return u.regs[k as int32];
}

function extAt(u: UnitIn, k: int64): ExtensionMethod | null {
	if (k == -1) return null;
	if (k < 0 || k >= u.exts.length) {
		u.miss(`extension ${k} is outside the unit`);
		return null;
	}
	return u.exts[k as int32];
}

function inEnum(u: UnitIn, v: int64, count: int32, what: string): int32 {
	if (v < 0 || v >= count) u.miss(`${what} ${v} is not one this compiler knows`);
	return v as int32;
}

export class StdUnitLoaded {
	base: CheckerContext = null as unknown as CheckerContext;
	modules: StdUnitModule[] = [];
	paths: HashSet<string> = new HashSet<string>();
	exportNames: HashMap<string, string[]> = new HashMap<string, string[]>();
	itemPaths: string[] = [];
	flagKeys: string[] = [];
	flagTextKeys: string[] = [];
	maybeKeys: string[] = [];
	maybeTypes: Type[] = [];
	duVariants: Type[] = [];
	defaults: DefaultsRows = new DefaultsRows();
	hooks: InstanceHookRows = new InstanceHookRows();
	held: HeldBeyondRows = new HeldBeyondRows();
	effects: string[] = [];
	ops: KeyedOp[] = [];
	opCanon: OpCanonRows = new OpCanonRows();
	linkFlags: string[] = [];
	linkObjects: string[] = [];
	wellKnown: WellKnownState[] = [];
	dispatchVersion: int32 = 0;
	dispatchEntries: DispMethodEntry[] = [];
	byClassKeys: Symbol[] = [];
	byClassLists: DispMethodEntry[][] = [];
	bySymKeys: Symbol[] = [];
	bySymEntries: DispMethodEntry[] = [];
	exportEntries: ModuleExports[] = [];
	cTagNames: string[] = [];
	cTagSyms: Symbol[] = [];
}

function readGlobals(u: UnitIn, out: StdUnitLoaded, cache: IdentCache): void {
	if (u.row("w")) {
		const names = u.getTexts();
		for (const name of names) getIdentId(cache, name);
		if (cache.counter != names.length) u.miss("the interned names repeat");
		u.close();
	}
	if (u.row("i")) {
		const ids = u.getIntList();
		if (ids.length != u.objs.syms.length) u.miss("name ids do not cover every symbol");
		for (let i = 0; i < ids.length && i < u.objs.syms.length; i += 1) {
			if (ids[i] < 0) u.miss(`a negative name id ${ids[i]}`);
			u.objs.syms[i].nameId = ids[i];
		}
		u.close();
	}
	if (u.row("m")) {
		out.itemPaths = u.getTexts();
		u.close();
	}
	if (u.row("f")) {
		out.flagKeys = u.getTexts();
		u.close();
	}
	if (u.row("F")) {
		out.flagTextKeys = u.getTexts();
		u.close();
	}
	if (u.row("y")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			out.maybeKeys.push(u.getText());
			out.maybeTypes.push(u.getType() as Type);
		}
		u.close();
	}
	if (u.row("v")) {
		out.duVariants = u.getTypes();
		u.close();
	}
	if (u.row("d")) {
		out.defaults.checked = u.getNodes();
		u.close();
	}
	if (u.row("D")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			out.defaults.stored.push(u.getNode() as Node);
			out.defaults.sources.push(u.getNode() as Node);
		}
		u.close();
	}
	const hooks = out.hooks;
	if (u.row("h")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("H")) break;
			hooks.owners.push(u.getSym() as Symbol);
			hooks.ops.push(inEnum(u, u.getInt(), (AttachedOp.AttachedReach as int32) + 1, "attached op") as AttachedOp);
			hooks.syms.push(u.getSym() as Symbol);
			hooks.concreteTypes.push(u.getTypes());
			u.close();
		}
	}
	if (u.row("c")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("C")) break;
			hooks.scannedOwners.push(u.getSym() as Symbol);
			hooks.scanned.push(u.getTypes());
			u.close();
		}
	}
	if (u.row("k")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("K")) break;
			hooks.typedOwners.push(u.getSym() as Symbol);
			hooks.typed.push(u.getTypes());
			u.close();
		}
	}
	if (u.row("b")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("B")) break;
			out.held.syms.push(u.getSym() as Symbol);
			out.held.symHeld.push(u.getTypes());
			u.close();
		}
	}
	if (u.row("q")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("Q")) break;
			out.held.fieldNames.push(u.getText());
			out.held.slots.push(u.getType() as Type);
			out.held.slotHeld.push(u.getTypes());
			u.close();
		}
	}
	if (u.row("e")) {
		out.effects = u.getTexts();
		u.close();
	}
	if (u.row("o")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("O")) break;
			const key = u.getText();
			const sym = u.getSym();
			const canon = u.getBool();
			if (sym == null) u.miss("a type-bound op has no symbol");
			out.ops.push({ key, sym: sym as Symbol, canon });
			u.close();
		}
	}
	if (u.row("+")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			out.opCanon.syms.push(u.getSym() as Symbol);
			out.opCanon.keys.push(u.getText());
		}
		u.close();
	}
	if (u.row("l")) {
		out.linkFlags = u.getTexts();
		u.close();
	}
	if (u.row("L")) {
		out.linkObjects = u.getTexts();
		u.close();
	}
	readWellKnown(u, out);
}

class WellKnownState {
	typeFlags: uint32 = 0;
	typeValue: int32 = 0;
	callConv: int32 = 0;
	children: Type[] | null = null;
	typeReturn: Type | null = null;
	typeExtra: Type | null = null;
	typeParamDefault: Type | null = null;
	attachedOps: (Symbol | null)[] = [];
	sym: Symbol | null = null;
	typeInst: Type | null = null;
	readonlyView: Type | null = null;
	mutableView: Type | null = null;
	ownedType: Type | null = null;
	plainType: Type | null = null;
	typeName: string = "";
	typeNames: string[] | null = null;
	optionalFields: string[] | null = null;
}

function readOptionalTexts(u: UnitIn): string[] | null {
	const present = u.getBool();
	const items = u.getTexts();
	return present ? items : null;
}

function readWellKnown(u: UnitIn, out: StdUnitLoaded): void {
	if (!u.row("*")) return;
	const known = wellKnownTypes();
	const n = u.getCount();
	u.close();
	if (n != known.length) u.miss(`the unit holds ${n} well-known types, this compiler ${known.length}`);
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row("^")) return;
		const state = new WellKnownState();
		const kind = u.getInt();
		if (kind != (known[i].kind as int32)) u.miss(`well-known type ${i} is of another kind`);
		state.typeFlags = u.getInt() as uint32;
		state.typeValue = u.getI32();
		state.callConv = u.getI32();
		const children = u.getTypes();
		state.children = u.getBool() ? children : null;
		state.typeReturn = u.getType();
		state.typeExtra = u.getType();
		state.typeParamDefault = u.getType();
		for (const k of u.getIntList()) state.attachedOps.push(symAt(u, k));
		state.sym = u.getSym();
		state.typeInst = u.getType();
		state.readonlyView = u.getType();
		state.mutableView = u.getType();
		state.ownedType = u.getType();
		state.plainType = u.getType();
		state.typeName = u.getText();
		state.typeNames = readOptionalTexts(u);
		state.optionalFields = readOptionalTexts(u);
		u.close();
		out.wellKnown.push(state);
	}
}

function applyWellKnown(states: WellKnownState[]): void {
	const known = wellKnownTypes();
	if (states.length != known.length) throw new Error(`internal: the std unit restores ${states.length} well-known types onto ${known.length}`);
	for (let i = 0; i < known.length; i += 1) {
		const t = known[i];
		const state = states[i];
		t.typeFlags = state.typeFlags as BitSet<TypeFlag>;
		t.typeValue = state.typeValue;
		t.callConv = state.callConv as CallingConvention;
		t.typeChildren = state.children as Type[];
		t.typeReturn = state.typeReturn;
		t.typeExtra = state.typeExtra;
		t.typeParamDefault = state.typeParamDefault;
		t.attachedOps = state.attachedOps;
		t.sym = state.sym;
		t.typeInst = state.typeInst;
		t.readonlyView = state.readonlyView;
		t.mutableView = state.mutableView;
		t.ownedType = state.ownedType;
		t.plainType = state.plainType;
		t.typeName = state.typeName;
		t.typeNames = state.typeNames as string[];
		t.optionalFields = state.optionalFields;
	}
}

function readDispatch(u: UnitIn, out: StdUnitLoaded): void {
	if (!u.row("r")) return;
	out.dispatchVersion = u.getI32();
	const n = u.getCount();
	u.close();
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row("R")) return;
		const classSym = u.getSym();
		const methodName = u.getText();
		const sym = u.getSym();
		const overloaded = u.getBool();
		const version = u.getI32();
		if (classSym == null || sym == null) u.miss("a dispatch entry without its class or method");
		out.dispatchEntries.push({ classSym: classSym as Symbol, methodName, sym: sym as Symbol, overloaded, version });
		u.close();
	}
	const entryAt = (k: int32): DispMethodEntry => {
		if (k < 0 || k >= out.dispatchEntries.length) {
			u.miss(`dispatch entry ${k} is outside the registry`);
			return null as unknown as DispMethodEntry;
		}
		return out.dispatchEntries[k];
	};
	if (!u.row("u")) return;
	const classes = u.getCount();
	u.close();
	for (let i = 0; i < classes && u.problem == ""; i += 1) {
		if (!u.row("U")) return;
		const owner = u.getSym();
		const list: DispMethodEntry[] = [];
		for (const k of u.getIntList()) list.push(entryAt(k));
		if (owner == null) u.miss("a dispatch class index without its class");
		out.byClassKeys.push(owner as Symbol);
		out.byClassLists.push(list);
		u.close();
	}
	if (!u.row("p")) return;
	const syms = u.getCount();
	u.close();
	for (let i = 0; i < syms && u.problem == ""; i += 1) {
		if (!u.row("P")) return;
		const sym = u.getSym();
		const entry = entryAt(u.getI32());
		if (sym == null) u.miss("a dispatch symbol index without its symbol");
		out.bySymKeys.push(sym as Symbol);
		out.bySymEntries.push(entry);
		u.close();
	}
}

function linkOwn(r: ExtensionRegistry): void {
	for (let i = 0; i < r.own.length; i += 1) {
		const name = r.own[i].methodName;
		const tail = r.byNameTail.get(name) ?? -1;
		r.byNameNext.push(-1);
		r.byNamePrev.push(tail);
		if (tail >= 0) r.byNameNext[tail] = i as int32;
		else r.byNameHead.set(name, i as int32);
		r.byNameTail.set(name, i as int32);
	}
}

function readExtensions(u: UnitIn): void {
	if (!u.row("x")) return;
	const n = u.getCount();
	u.close();
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row("X")) return;
		const methodName = u.getText();
		const sourcePath = u.getText();
		const isStatic = u.getBool();
		const sym = u.getSym();
		const scopeDepth = u.getInt() as number;
		const m: ExtensionMethod = { methodName, sourcePath, isStatic, sym, scopeDepth };
		u.exts.push(m);
		u.close();
	}
	if (!u.row("g")) return;
	const count = u.getCount();
	u.close();
	const bases: int64[] = [];
	const layers: int64[] = [];
	for (let i = 0; i < count && u.problem == ""; i += 1) u.regs.push(createExtensionRegistry());
	for (let i = 0; i < count && u.problem == ""; i += 1) {
		if (!u.row("G")) return;
		const r = u.regs[i];
		bases.push(u.getInt());
		r.baseCount = u.getI32();
		r.sealed = u.getBool();
		r.truncations = u.getI32();
		layers.push(u.getInt());
		r.sourceSeen = u.getI32();
		r.sourceTruncations = u.getI32();
		for (const k of u.getIntList()) {
			const m = extAt(u, k);
			if (m == null) u.miss("a registry holds no extension at one of its slots");
			else r.own.push(m);
		}
		u.close();
	}
	for (let i = 0; i < u.regs.length && u.problem == ""; i += 1) {
		const r = u.regs[i];
		r.base = regAt(u, bases[i]);
		r.exportLayer = regAt(u, layers[i]);
		linkOwn(r);
	}
}

function readExports(u: UnitIn, out: StdUnitLoaded): void {
	if (!u.row("z")) return;
	const n = u.getCount();
	u.close();
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row("Z")) return;
		const modulePath = u.getText();
		const count = u.getCount();
		u.close();
		const symbols: ExportedSymInfo[] = [];
		for (let j = 0; j < count && u.problem == ""; j += 1) {
			if (!u.row("Y")) return;
			const name = u.getText();
			const sym = u.getSym();
			const ext = extAt(u, u.getInt());
			const overloadExts: (ExtensionMethod | null)[] = [];
			for (const k of u.getIntList()) overloadExts.push(extAt(u, k));
			const converterTargetType = u.getType();
			if (sym == null) u.miss(`an export '${name}' of ${modulePath} has no symbol`);
			symbols.push({ name, sym: sym as Symbol, ext, overloadExts, converterTargetType, keep: u.objs.nodes });
			u.close();
		}
		out.exportEntries.push({ modulePath, symbols });
	}
	if (!u.row("a")) return;
	const tags = u.getCount();
	for (let i = 0; i < tags && u.problem == ""; i += 1) {
		out.cTagNames.push(u.getText());
		out.cTagSyms.push(u.getSym() as Symbol);
	}
	u.close();
}

function readModules(u: UnitIn, out: StdUnitLoaded, db: TransAmDb, graph: ModuleGraph): void {
	if (!u.row("n")) return;
	const n = u.getCount();
	u.close();
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row("M")) return;
		const m = new StdUnitModule();
		m.path = u.getText();
		const program = u.getNode();
		if (program != null) m.program = program;
		else u.miss(`${m.path} has no checked tree`);
		m.record.durability = inEnum(u, u.getInt(), (TaDurability.High as int32) + 1, "durability") as TaDurability;
		m.record.collected = u.getBool();
		for (const kind of u.getIntList()) m.record.kinds.push(inEnum(u, kind, (TaQueryKind.Dispatch as int32) + 1, "query kind") as TaQueryKind);
		m.exportNames = u.getTexts();
		m.record.paths = u.getTexts();
		u.close();
		if (m.record.kinds.length != m.record.paths.length) u.miss(`the check record of ${m.path} lists ${m.record.kinds.length} kinds for ${m.record.paths.length} paths`);
		const mod = findModule(graph, m.path);
		if (mod == null || !mod.stdPrelude || (mod.source == "" && mod.program == null)) {
			u.miss(`${m.path} is not a prelude module this graph checks`);
			continue;
		}
		const missing = dbCheckRecordMissing(db, m.record);
		if (missing != "") u.miss(`${m.path} depends on ${missing}, which this db does not hold`);
		out.modules.push(m);
		out.paths.add(m.path);
		out.exportNames.set(m.path, m.exportNames);
	}
}

function readTextLists(u: UnitIn): string[][] | null {
	if (!u.getBool()) return null;
	const n = u.getCount();
	const out: string[][] = [];
	for (let i = 0; i < n && u.problem == ""; i += 1) out.push(u.getTexts());
	return out;
}

function readContext(u: UnitIn, ctx: CheckerContext, cache: IdentCache): void {
	if (u.row("0")) {
		ctx.gcMode = inEnum(u, u.getInt(), (GcMode.Manual as int32) + 1, "gc mode") as GcMode;
		ctx.targetOs = u.getText();
		ctx.appMode = u.getText();
		ctx.stdRoot = u.getText();
		ctx.strictNullChecks = u.getBool();
		ctx.typeTestDepth = u.getI32();
		ctx.inLoop = u.getBool();
		ctx.inSwitch = u.getBool();
		ctx.decoratorsPending = u.getBool();
		ctx.inTestBlock = u.getBool();
		ctx.pendingSpawnThunk = u.getBool();
		ctx.macroExpansionDepth = u.getI32();
		ctx.jsxMacroArgDepth = u.getI32();
		ctx.symRecordsOff = u.getBool();
		ctx.compileTimeBodyDepth = u.getInt() as number;
		ctx.inTryExpr = u.getBool();
		ctx.genericInstDepth = u.getI32();
		ctx.condEvalDepth = u.getI32();
		ctx.inGenericContext = u.getI32();
		ctx.itemModule = u.getI32();
		ctx.nextItem = u.getI32();
		ctx.cancelVersion = u.getI32();
		ctx.modulePath = u.getText();
		ctx.includeDirectives = u.getText();
		ctx.compileDirectives = u.getText();
		ctx.compilerFlags = u.getText();
		u.close();
	}
	if (u.row("1")) {
		ctx.currentFunction = u.getSym();
		ctx.currentActor = u.getSym();
		ctx.staticBlockClass = u.getSym();
		ctx.jsxConsumer = u.getSym();
		ctx.tryGuardedFunction = u.getSym();
		ctx.refillTarget = u.getNode();
		ctx.refillValue = u.getNode();
		ctx.awaitedCall = u.getNode();
		ctx.topProgram = u.getNode();
		ctx.stmtPosExpr = u.getNode() as Node;
		ctx.typeExprSlot = u.getNode() as Node;
		ctx.calleeExpr = u.getNode() as Node;
		ctx.conversionOperand = u.getNode() as Node;
		ctx.awaitedPayload = u.getType();
		ctx.inferredReturn = u.getType() as Type;
		ctx.matchArmExpected = u.getType();
		ctx.conversionTarget = u.getType() as Type;
		ctx.instantiatingCtx = u.getCtx() as CheckerContext;
		const reg = regAt(u, u.getInt());
		if (reg == null) u.miss(`${ctx.modulePath} has no extension registry`);
		else ctx.extensionRegistry = reg;
		u.close();
	}
	if (u.row("2")) {
		ctx.staticBlockPending = u.getNodes();
		ctx.identifierMoves = u.getNodes();
		ctx.computedGotoMarks = u.getNodes();
		ctx.inferredReturnStmts = u.getNodes();
		ctx.inferredReturnTries = u.getNodes();
		ctx.armTails = u.getNodes();
		ctx.pendingHoisted = u.getNodes();
		ctx.pendingTrailing = u.getNodes();
		ctx.generatedInstances = u.getNodes();
		ctx.pendingLocalTypeDecls = u.getNodes();
		ctx.liftedLocalTypeDecls = u.getNodes();
		u.close();
	}
	if (u.row("3")) {
		ctx.instantiationSites = u.getTexts();
		u.close();
	}
	if (u.row("4")) {
		const n = u.getCount();
		const locks: LockedMove[] = [];
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const move = u.getNode() as Node;
			const routine = u.getNode() as Node;
			locks.push({ move, routine });
		}
		ctx.lockedMoves = locks;
		u.close();
	}
	if (u.row("5")) {
		ctx.ctorExits = readTextLists(u);
		u.close();
	}
	if (u.row("6")) {
		ctx.ctorExitsNext = readTextLists(u);
		u.close();
	}
	readScopes(u, ctx, cache);
	if (u.row("9")) {
		const n = u.getCount();
		u.close();
		const errors: CheckerError[] = [];
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("!")) break;
			const message = u.getText();
			const line = u.getI32();
			const column = u.getI32();
			const endLine = u.getI32();
			const endColumn = u.getI32();
			const fatal = u.getBool();
			const severity = inEnum(u, u.getInt(), (Severity.Hint as int32) + 1, "severity") as Severity;
			const tags = u.getInt() as number;
			errors.push({ message, line, column, endLine, endColumn, fatal, severity, tags });
			u.close();
		}
		ctx.errors = errors;
	}
	if (u.row("j")) {
		for (const s of u.getSyms()) ctx.capturedSyms.add(s);
		u.close();
	}
	if (u.row("k")) {
		const n = u.getCount();
		const convs: MacroConverter[] = [];
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const sym = u.getSym() as Symbol;
			const tier = u.getI32();
			convs.push({ sym, tier });
		}
		ctx.macroConverters = convs;
		u.close();
	}
	if (u.row("l")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const sym = u.getSym() as Symbol;
			ctx.converterTargetTypes.set(sym, u.getType() as Type);
		}
		u.close();
	}
	if (u.row("m")) {
		ctx.runtimeConverters = u.getSyms();
		u.close();
	}
	if (u.row("n")) {
		const n = u.getCount();
		u.close();
		const imports: JsImportEntry[] = [];
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("@")) break;
			const modulePath = u.getText();
			const names = u.getTexts();
			imports.push({ modulePath, names });
			u.close();
		}
		ctx.jsImportRegistry = imports;
	}
	readInstCache(u, "o", "O", ctx.procInstCache);
	readInstCache(u, "p", "P", ctx.typeInstCache);
	if (u.row("q")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const name = u.getText();
			ctx.disambTable.set(name, u.getI32());
		}
		u.close();
	}
	if (u.row("r")) {
		if (u.getBool()) {
			const after = new HashMap<string, int32>();
			const n = u.getCount();
			for (let i = 0; i < n && u.problem == ""; i += 1) {
				const name = u.getText();
				after.set(name, u.getI32());
			}
			ctx.disambAfterCheck = after;
		}
		u.close();
	}
	if (u.row("s")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const name = u.getText();
			ctx.localTypeNames.set(name, u.getBool());
		}
		u.close();
	}
	if (u.row("t")) {
		ctx.interf = u.getSyms();
		u.close();
	}
	if (u.row("u")) {
		for (const s of u.getSyms()) ctx.interfSet.add(s);
		u.close();
	}
	if (u.row("v")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("V")) break;
			const sym = u.getSym() as Symbol;
			ctx.interfNames.set(sym, u.getTexts());
			u.close();
		}
	}
	if (u.row("x")) {
		for (const name of u.getTexts()) ctx.explicitExportNames.add(name);
		u.close();
	}
	if (u.row("y")) {
		for (const s of u.getSyms()) ctx.importSet.add(s);
		u.close();
	}
	if (u.row("z")) {
		for (const s of u.getSyms()) ctx.usedImports.add(s);
		u.close();
	}
	if (u.row("A")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const key = u.getSym() as Symbol;
			ctx.shadowedImports.set(key, u.getSym() as Symbol);
		}
		u.close();
	}
	if (u.row("B")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("b")) break;
			const spec = u.getText();
			const owner = u.getInt();
			const members = u.getSyms();
			ctx.preludeInterf.set(spec, members);
			if (owner != -1) {
				const alias = new InterfAlias();
				alias.holder = ctx;
				alias.spec = spec;
				alias.owner = owner;
				alias.members = members;
				u.aliases.push(alias);
			}
			u.close();
		}
	}
	if (u.row("C")) {
		for (const s of u.getSyms()) ctx.preludeExports.add(s);
		u.close();
	}
	if (u.row("D")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("d")) break;
			const path = u.getText();
			ctx.preludeModuleScopes.set(path, u.getSyms());
			u.close();
		}
	}
	if (u.row("E")) {
		for (const path of u.getTexts()) ctx.ownModules.add(path);
		u.close();
	}
	if (u.row("F")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const name = u.getText();
			const sym = u.getSym();
			if (sym == null) u.miss(`compiler function '${name}' has no symbol`);
			else ctx.compilerFuncs.set(name, sym);
		}
		u.close();
	}
	if (u.row("J")) {
		const tracker = ctx.initTracker;
		tracker.currentBlock = u.getInt() as number;
		tracker.leftPartOfAsgn = u.getInt() as number;
		tracker.assignTarget = u.getNode();
		tracker.definiteTarget = u.getNode();
		tracker.argIdents = u.getNodes();
		tracker.pendingReads = u.getNodes();
		const blocks: number[] = [];
		for (const block of u.getIntList()) blocks.push(block as number);
		tracker.declBlocks = blocks;
		tracker.initialized = u.getTexts();
		tracker.declScopes = u.getTexts();
		tracker.outParams = u.getTexts();
		u.close();
	}
	if (u.row("K")) {
		ctx.affineTracker.floor = u.getI32();
		ctx.affineTracker.floors = u.getIntList();
		ctx.affineTracker.consumed = u.getTexts();
		u.close();
	}
	if (u.row("L")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const key = u.getNode() as Node;
			ctx.adoptedDecls.set(key, u.getSym() as Symbol);
		}
		u.close();
	}
	if (u.row("M")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const key = u.getNode() as Node;
			ctx.adoptedParams.set(key, u.getSyms());
		}
		u.close();
	}
	if (u.row("I")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const key = u.getNode() as Node;
			ctx.boundIdents.set(key, u.getSym() as Symbol);
		}
		u.close();
	}
	if (u.row("W")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const key = u.getNode() as Node;
			ctx.inferredNeeds.set(key, u.getNodes());
		}
		u.close();
	}
	if (u.row("X")) {
		const n = u.getCount();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			const key = u.getNode() as Node;
			ctx.inferredOwners.set(key, u.getNode() as Node);
		}
		u.close();
	}
	if (u.row("Y")) {
		const n = u.getCount();
		u.close();
		for (let i = 0; i < n && u.problem == ""; i += 1) {
			if (!u.row("y")) break;
			const key = u.getNode() as Node;
			ctx.expansionFriends.set(key, u.getTexts());
			u.close();
		}
	}
	if (u.row("Z")) {
		for (const n of u.getNodes()) ctx.constContext.add(n);
		u.close();
	}
}

function readScopes(u: UnitIn, ctx: CheckerContext, cache: IdentCache): void {
	if (!u.row("7")) return;
	const n = u.getCount();
	const current = u.getInt();
	const readonlyAt = u.getInt();
	const staticInitAt = u.getInt();
	const hookBodyAt = u.getInt();
	u.close();
	const scopes: Scope[] = [];
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row("8")) return;
		const kind = inEnum(u, u.getInt(), (ScopeKind.Loop as int32) + 1, "scope kind") as ScopeKind;
		const parent = u.getInt();
		const privateAccess = u.getSym();
		const keys = u.getIntList();
		const members = u.getSyms();
		const friendModules = u.getTexts();
		u.close();
		const scope: Scope = { symbols: new Map<int32, Symbol>(), scopeKind: kind, parent: null, privateAccess, friendModules };
		if (parent >= 0 && parent < i) scope.parent = scopes[parent as int32];
		else if (parent != -1) u.miss("a scope's parent does not come before it");
		if (keys.length != members.length) u.miss("a scope lists unequal keys and symbols");
		for (let k = 0; k < keys.length && k < members.length; k += 1) {
			if (keys[k] < 1) u.miss(`a scope key ${keys[k]}`);
			scope.symbols.set(keys[k], members[k]);
		}
		scopes.push(scope);
	}
	const scopeAt = (k: int64): Scope | null => {
		if (k == -1) return null;
		if (k < 0 || k >= scopes.length) {
			u.miss(`scope ${k} is outside the carried scopes`);
			return null;
		}
		return scopes[k as int32];
	};
	const currentScope = scopeAt(current);
	if (currentScope == null) {
		u.miss(`${ctx.modulePath} has no current scope`);
		return;
	}
	const table: SymbolTable = { current: currentScope, allScopes: scopes, identCache: cache };
	ctx.table = table;
	const readonlyScope = scopeAt(readonlyAt);
	const staticInitScope = scopeAt(staticInitAt);
	const hookBodyScope = scopeAt(hookBodyAt);
	if (readonlyScope != null) ctx.readonlyBoundary = readonlyScope;
	if (staticInitScope != null) ctx.staticInitBoundary = staticInitScope;
	if (hookBodyScope != null) ctx.hookBodyBoundary = hookBodyScope;
}

function readInstCache(u: UnitIn, headTag: string, rowTag: string, cache: HashMap<Symbol, CheckedInstantiation[]>): void {
	if (!u.row(headTag)) return;
	const n = u.getCount();
	u.close();
	for (let i = 0; i < n && u.problem == ""; i += 1) {
		if (!u.row(rowTag)) return;
		const key = u.getSym() as Symbol;
		const count = u.getCount();
		const insts: CheckedInstantiation[] = [];
		for (let j = 0; j < count && u.problem == ""; j += 1) {
			const sym = u.getSym() as Symbol;
			const params = u.getTypes();
			const concreteTypes = u.getTypes();
			insts.push({ sym, params, concreteTypes });
		}
		cache.set(key, insts);
		u.close();
	}
}

function decodeUnit(u: UnitIn, db: TransAmDb, graph: ModuleGraph): StdUnitLoaded {
	const out = new StdUnitLoaded();
	const phases = env.get("MSC_STD_UNIT_PHASES") != "";
	const t0 = performance.now();
	let tag = u.rd.startRow();
	while (tag >= 0 && u.objs.readObjectRow(tag, u.rd)) {
		if (u.rd.bad) {
			u.miss("a malformed object row");
			return out;
		}
		tag = u.rd.startRow();
	}
	const pos = u.rd.pos;
	const last = u.rd.last;
	const t1 = performance.now();
	if (!u.objs.linkTypesAndSymbols() || !u.objs.linkNodes(u.rd)) {
		u.miss("the object rows do not link");
		return out;
	}
	if (phases) console.log(`    stdUnit phases: rows=${t1 - t0}ms link=${performance.now() - t1}ms T=${u.objs.types.length} N=${u.objs.nodes.length} S=${u.objs.syms.length}`);
	u.rd.pos = pos;
	u.rd.last = last;
	u.peeked = tag;
	const base = createGraphPreludeContext(db.dispatchRegistry);
	const cache = base.table.identCache;
	out.base = base;
	readGlobals(u, out, cache);
	readDispatch(u, out);
	readExtensions(u);
	readExports(u, out);
	readModules(u, out, db, graph);
	if (u.problem != "") return out;
	u.ctxs.push(base);
	for (const m of out.modules) {
		const mod = findModule(graph, m.path)!;
		const ctx = createContextWithCache(cache, db.dispatchRegistry);
		ctx.moduleGraph = graph;
		ctx.currentModule = mod;
		ctx.exportRegistry = db.exportRegistry;
		ctx.cancelCtx = db.cancelCtx;
		ctx.preludeCtx = base;
		ctx.compilerFuncs = base.compilerFuncs;
		m.ctx = ctx;
		u.ctxs.push(ctx);
	}
	for (const ctx of u.ctxs) ctx.outOfTree = u.objs.nodes;
	for (let i = 0; i < u.ctxs.length && u.problem == ""; i += 1) readContext(u, u.ctxs[i], cache);
	for (const alias of u.aliases) {
		const owner = alias.owner >= 0 && alias.owner < u.ctxs.length ? u.ctxs[alias.owner as int32] : null;
		if (owner == null || owner.interf.length != alias.members.length) {
			u.miss(`the prelude interface of '${alias.spec}' names a context whose interface differs`);
			continue;
		}
		for (let i = 0; i < alias.members.length; i += 1) {
			if (owner.interf[i] != alias.members[i]) u.miss(`the prelude interface of '${alias.spec}' differs from its module's`);
		}
		alias.holder.preludeInterf.set(alias.spec, owner.interf);
	}
	for (const m of out.modules) {
		if (m.ctx.modulePath != m.path) u.miss(`the context restored for ${m.path} checked ${m.ctx.modulePath}`);
	}
	if (u.row(".")) u.close();
	if (u.rd.startRow() >= 0) u.miss("rows follow the end of the unit");
	return out;
}

function loadMiss(started: float64, why: string): StdUnitLoaded | null {
	_loadMs = _loadMs + (performance.now() - started);
	note("miss", why);
	return null;
}

export function loadStdUnit(keyText: string, db: TransAmDb, graph: ModuleGraph): StdUnitLoaded | null {
	const started = performance.now();
	const path = unitPath(keyText);
	if (path == "") return loadMiss(started, "the global cache is off");
	if (db.exportRegistry.entries.length != 0 || db.dispatchRegistry.entries.length != 0 || db.contexts.size != 0) return loadMiss(started, "the db already holds checks");
	const body = try readFile(path) catch "";
	if (body == "") return loadMiss(started, "no unit");
	if (env.get("MSC_STD_UNIT_PHASES") != "") console.log(`    stdUnit phases: read=${performance.now() - started}ms`);
	const header = unitHeader(keyText);
	if (!body.startsWith(header)) return loadMiss(started, "a foreign or mismatched unit");
	const u = new UnitIn(body);
	u.rd.pos = header.byteLength as int32;
	let loaded = new StdUnitLoaded();
	try {
		loaded = decodeUnit(u, db, graph);
	} catch (e) {
		u.miss(`the reader threw: ${(e as Error).message}`);
	}
	if (u.problem != "") return loadMiss(started, u.problem);
	if (env.get("MSC_STD_UNIT_PHASES") != "") console.log(`    stdUnit phases: decoded=${performance.now() - started}ms`);
	markUsed(path, nowSeconds());
	_bytes = body.byteLength as int64;
	_loadMs = _loadMs + (performance.now() - started);
	note("hit", "");
	return loaded;
}

export function applyStdUnit(loaded: StdUnitLoaded, db: TransAmDb, graph: ModuleGraph): void {
	const started = performance.now();
	applyWellKnown(loaded.wellKnown);
	replayMaybeCache(loaded.maybeKeys, loaded.maybeTypes);
	replayDuVariants(loaded.duVariants);
	prewarmRoutineFlags(loaded.flagKeys);
	prewarmRoutineFlagTexts(loaded.flagTextKeys);
	for (let i = 0; i < loaded.itemPaths.length; i += 1) {
		if (moduleItemId(loaded.itemPaths[i]) != i) throw new Error(`internal: the std unit replays item module ${i} as ${loaded.itemPaths[i]}, which this process already numbered`);
	}
	for (const m of loaded.modules) {
		if (m.ctx.itemModule != moduleItemId(m.path)) throw new Error(`internal: the std unit restored ${m.path} as item module ${m.ctx.itemModule}`);
	}
	replayDefaults(loaded.defaults);
	replayInstanceHooks(loaded.hooks);
	replayHeldBeyond(loaded.held);
	restoreEffectsAfterPrelude(loaded.effects, graph);
	replayOps(loaded.ops);
	replayOpCanonRows(loaded.opCanon);
	for (const flag of loaded.linkFlags) linkFlags().add(flag);
	for (const object of loaded.linkObjects) linkObjects().add(object);
	const dispatch = db.dispatchRegistry;
	for (const entry of loaded.dispatchEntries) dispatch.entries.push(entry);
	for (let i = 0; i < loaded.byClassKeys.length; i += 1) dispatch.byClass.set(loaded.byClassKeys[i], loaded.byClassLists[i]);
	for (let i = 0; i < loaded.bySymKeys.length; i += 1) dispatch.bySym.set(loaded.bySymKeys[i], loaded.bySymEntries[i]);
	dispatch.version = loaded.dispatchVersion;
	for (const entry of loaded.exportEntries) registerModuleExports(db.exportRegistry, entry.modulePath, entry.symbols);
	for (let i = 0; i < loaded.cTagNames.length; i += 1) db.exportRegistry.cTags.set(loaded.cTagNames[i], loaded.cTagSyms[i]);
	for (const m of loaded.modules) dbRestoreCheck(db, m.path, m.ctx, m.program, m.record);
	if (loaded.modules.length > 0) {
		const last = loaded.modules[loaded.modules.length - 1];
		enterComptimeOuter(last.ctx, last.program);
	}
	_loadMs = _loadMs + (performance.now() - started);
}

export function adoptStdUnitTarget(loaded: StdUnitLoaded): void {
	for (const m of loaded.modules) m.ctx.targetInfo = loaded.base.targetInfo;
}

export function verifyRestoredExports(loaded: StdUnitLoaded, path: string, names: string[]): void {
	const cold = loaded.exportNames.get(path);
	if (cold == null) return;
	if (cold.join("\n") != names.join("\n")) throw new Error(`internal: the std unit restored ${path} with exports [${names.join(", ")}], its cold check collected [${cold.join(", ")}]`);
}
