// Prelude Pack — disk cache for buildPreludeContext's result (BUILD-PERF §6, Phase A1)
//
// The prelude block re-reads, re-translates and re-checks the same ~45 std
// modules in EVERY msc process (~150-250 ms after A0). This pack persists the
// checked symbol table so a warm build starts from the finished scope:
//
//   toolStamp = msc binary + runtime/ + vendor/ content (same inputs the
//               object cache's toolchainStamp uses, recomputed locally — this
//               module is deliberately self-contained: checker/ must not
//               import compiler/, only compiler/meta/callbacks-style bridges
//               are sanctioned)
//   stdTreeHash = content hash of the whole std/ tree (covers sub-modules,
//               std-local headers, per-backend variants — over-invalidation
//               on unused files is accepted for v1)
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

import { Symbol, SymbolFlag, NodeFlag, SymbolKind, SymbolState, Type, TypeKind, TypeFlag, Node, NodeData, NodeKind, SourceLocation, CallingConvention, makeLoc, createNodeAt, DeclKind, ExternKind, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData, FunctionExprData, TypeAssertionData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, HiddenStdConvData, ExprStmtData, TypeAnnotationData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, DestructuringDeclData, VariableDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, BlockStmtData, ReturnStmtData, FunctionDeclData, DoWhileStmtData, SwitchStmtData, SwitchCaseData, MatchStmtData, ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData, ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData, ThrowStmtData, TryCatchStmtData, MacroInvocationData, DecoratedDeclData, DeferStmtData, TestDeclData, AssertStmtData, ExternDeclData, MacroDeclData, QuoteExprData, ComptimeBlockData, TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData, ProgramData, ActorDeclData, SpliceManyData, JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData, NumberLiteralData, StringLiteralData, BooleanLiteralData, BigIntLiteralData, RegexLiteralData, IdentifierData, BreakStmtData, ContinueStmtData, UnreachableStmtData } from "../ast/node";
import { FieldSink, nodeFields, pkSamples, pkDumpNode } from "../ast/fieldspec";
import { CheckerContext, createContextWithCache, createExtensionRegistry, createExtMethod, registerExtension } from "./context";
import { createIdentCache, getIdentId, identName } from "./idents";
import { emptyType, noneType, createGenericParam, createKeyOfType } from "./types";
import { makeSymbolState } from "./symbol";
import { resolveRuntimeDir, resolveArgv0 } from "../utils/path";
import { getParserDefines, setParserDefines } from "../parser/context";
import { defineIdentity, createDefineTable, defineSymbol } from "../compiler/defines";
import { defaultGlobalImports, setExtraGlobalImports } from "./prelude";
import { readFile, writeFile, exists, remove, removeAll, ensureDir, rename } from "std/fs";
import { env, argv } from "std/process";
import { collectStaleEntries, nowSeconds } from "../utils/stampDirs";
import { hashContent, collectFilesSorted } from "../utils/contentHash";

const PACK_MAGIC = "MSPK5";

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

// compile.ms registers compiler/cache.toolchainStamp at load (memoized there
// — one stamp computation per process shared with the object cache). Without
// registration (standalone tests) a local equivalent is computed, for the std tree as well.
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
	let acc = hashFile(resolveArgv0(argv[0]));
	const root = resolveRuntimeDir();
	if (root != "") {
		acc = stampTreePack(acc, join(root, "runtime"), "runtime/");
		acc = stampTreePack(acc, join(root, "vendor"), "vendor/");
	}
	_toolStamp = hashContent(acc);
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
	if (env.get("MSC_NO_GLOBAL_CACHE") != "") return "";
	const home = env.get("HOME");
	const base = home != "" ? home : env.get("USERPROFILE");
	if (base == "") return "";
	return `${base}/.metascript/cache/prelude`;
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
	const w = writeFile(tmp, content);
	if (!w.ok) return false;
	const r = rename(tmp, path);
	if (r.ok) return true;
	remove(tmp);
	return false;
}

// ===== Escaping =====
// Fields are tab-separated, comma-joined lists. Escape: \\ \n \r \t , so no
// raw separator can appear inside a value.

function hexDigitByte(v: int32): uint8 {
	return (v < 10 ? 48 + v : 87 + v) as uint8;
}

function hexValByte(c: int32): int32 {
	if (c >= 48 && c <= 57) return c - 48;
	if (c >= 97 && c <= 102) return c - 87;
	if (c >= 65 && c <= 70) return c - 55;
	return 0;
}

// Escapes the separators AND every byte >= 0x80 (as \xHH). The non-ASCII
// escape is a PERFORMANCE invariant, not cosmetics: it makes the whole pack
// pure ASCII, which is what lets the reader use the character-indexed string
// ops (indexOf/slice). On a non-ASCII string those re-walk the UTF-8 from the
// start on every call (runtime/core/string.c), so scanning a 2 MB blob with
// them is quadratic — that is what hung the loader before. 97 std files carry
// non-ASCII bytes, so the payload is never accidentally ASCII.
export function escapeP(s: string): string {
	if (s == "") return "";
	const b = s.asBytes();
	const out: uint8[] = [];
	let i = 0;
	while (i < b.length) {
		const c = b[i] as int32;
		if (c == 92) { out.push(92); out.push(92); }
		else if (c == 10) { out.push(92); out.push(110); }
		else if (c == 13) { out.push(92); out.push(114); }
		else if (c == 9) { out.push(92); out.push(116); }
		else if (c == 44) { out.push(92); out.push(99); }
		else if (c >= 128) {
			out.push(92);
			out.push(120);
			out.push(hexDigitByte((c / 16) as int32));
			out.push(hexDigitByte((c % 16) as int32));
		} else out.push(c as uint8);
		i = i + 1;
	}
	return out.asString();
}

export function unescapeP(s: string): string {
	if (s == "") return "";
	// Early-out BEFORE asBytes: the pack is ASCII, so indexOf takes the runtime's
	// memcmp path, while asBytes copies the whole field into a fresh uint8[].
	// Most fields carry no escape at all, and the reader unescapes ~400k of them.
	if (s.indexOf("\\", 0) < 0) return s;
	const b = s.asBytes();
	const out: uint8[] = [];
	let i = 0;
	while (i < b.length) {
		const c = b[i] as int32;
		if (c == 92 && i + 1 < b.length) {
			const n = b[i + 1] as int32;
			if (n == 110) { out.push(10); i = i + 2; continue; }
			if (n == 114) { out.push(13); i = i + 2; continue; }
			if (n == 116) { out.push(9); i = i + 2; continue; }
			if (n == 99) { out.push(44); i = i + 2; continue; }
			if (n == 120 && i + 3 < b.length) {
				const hi = hexValByte(b[i + 2] as int32);
				const lo = hexValByte(b[i + 3] as int32);
				out.push(((hi * 16) + lo) as uint8);
				i = i + 4;
				continue;
			}
			out.push(n as uint8);
			i = i + 2;
			continue;
		}
		out.push(c as uint8);
		i = i + 1;
	}
	return out.asString();
}

export function joinCsv(items: string[]): string {
	if (items.length == 0) return "-";
	let out = "";
	let i = 0;
	while (i < items.length) {
		if (i > 0) out = out + ",";
		out = out + escapeP(items[i]);
		i = i + 1;
	}
	return out;
}

export function splitCsv(s: string): string[] {
	if (s == "-") return [];
	const out: string[] = [];
	let start = 0;
	let i = 0;
	const n = s.length;
	while (i < n) {
		const c = s.charCodeAt(i);
		if (c == 92) {
			i = i + 2;
			continue;
		}
		if (c == 44) {
			out.push(unescapeP(s.slice(start, i)));
			start = i + 1;
		}
		i = i + 1;
	}
	if (n > start || out.length > 0) out.push(unescapeP(s.slice(start, n)));
	return out;
}

function intsCsv(arr: int32[]): string {
	if (arr.length == 0) return "-";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + arr[i];
		i = i + 1;
	}
	return out;
}

// Fast int-list scan: digit accumulation straight off charCodeAt (O(1) on the
// ASCII pack), no per-element substring allocation. Escape sequences never
// occur in int lists, so the separator scan can ignore backslashes.
function parseIntsCsv(s: string): int32[] {
	if (s == "-" || s == "") return [];
	const out: int32[] = [];
	let i = 0;
	const n = s.length;
	while (i < n) {
		let neg = false;
		if (s.charCodeAt(i) == 45) {
			neg = true;
			i = i + 1;
		}
		let v: int32 = 0;
		while (i < n) {
			const c = s.charCodeAt(i);
			if (c >= 48 && c <= 57) {
				v = v * 10 + (c - 48);
				i = i + 1;
				continue;
			}
			break;
		}
		out.push(neg ? -v : v);
		i = i + 1;
	}
	return out;
}

// Scan with charCodeAt (O(1) on the ASCII pack) + one slice per element.
// The old char-concat builder (`cur = cur + ch`) allocated a fresh string per
// character — quadratic per field, and the reader splits hundreds of thousands
// of them.
function splitCsvRaw(s: string): string[] {
	if (s == "") return [];
	const out: string[] = [];
	let start = 0;
	let i = 0;
	const n = s.length;
	while (i < n) {
		const c = s.charCodeAt(i);
		if (c == 92) {
			i = i + 2;
			continue;
		}
		if (c == 44) {
			out.push(s.slice(start, i));
			start = i + 1;
		}
		i = i + 1;
	}
	if (n > start || out.length > 0) out.push(s.slice(start, n));
	return out;
}

function floatsCsv(arr: number[] | null): string {
	if (arr == null) return "-";
	if (arr.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + `${arr[i]}`;
		i = i + 1;
	}
	return out;
}

function parseFloatsCsv(s: string): number[] {
	if (s == "-" || s == "") return [];
	const parts = splitCsvRaw(s);
	const out: number[] = [];
	for (const p of parts) out.push(p.parseFloat());
	return out;
}

function locCsv4(loc: SourceLocation | null): string {
	if (loc == null) return "0,0,0,0";
	return `${loc.line},${loc.column},${loc.endLine},${loc.endColumn}`;
}

// SourceLocation[] flattening: "-" = null, "" = empty, else 4 ints per loc.
function locsCsv(locs: SourceLocation[] | null): string {
	if (locs == null) return "-";
	if (locs.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < locs.length) {
		if (i > 0) out = out + ",";
		out = out + locCsv4(locs[i]);
		i = i + 1;
	}
	return out;
}

function parseLoc(s: string): SourceLocation {
	const p = parseIntsCsv(s);
	if (p.length == 0) return makeLoc(0, 0);
	const l = makeLoc(p[0], p.length > 1 ? p[1] : 0);
	if (p.length > 2) l.endLine = p[2];
	if (p.length > 3) l.endColumn = p[3];
	return l;
}

function parseLocs(s: string): SourceLocation[] {
	if (s == "-" || s == "") return [];
	const p = parseIntsCsv(s);
	const out: SourceLocation[] = [];
	let k = 0;
	while (k + 3 < p.length) {
		const l = makeLoc(p[k], p[k + 1]);
		l.endLine = p[k + 2];
		l.endColumn = p[k + 3];
		out.push(l);
		k = k + 4;
	}
	return out;
}

// Writer-side node/type index views for the top-level payload emitter —
// writePreludePack assigns its local maps here before emitting N rows.
let _wnodeIdx = new HashMap<Node, int32>();
let _wtypeIdx = new HashMap<Type, int32>();

function idxNodeP(n: Node | null): int32 {
	if (n == null || !_wnodeIdx.has(n)) return -1;
	const v = _wnodeIdx.get(n);
	return v == null ? -1 : v;
}

function idxTypeP(t: Type | null): int32 {
	if (t == null || !_wtypeIdx.has(t)) return -1;
	const v = _wtypeIdx.get(t);
	return v == null ? -1 : v;
}

function idxsP(arr: Node[] | null): string {
	if (arr == null) return "-";
	if (arr.length == 0) return "";
	let out = "";
	let i = 0;
	while (i < arr.length) {
		if (i > 0) out = out + ",";
		out = out + idxNodeP(arr[i]);
		i = i + 1;
	}
	return out;
}

function nestedIdxsP(arrs: Node[][] | null): string {
	if (arrs == null) return "-";
	let out = "";
	let i = 0;
	while (i < arrs.length) {
		out = out + idxsP(arrs[i]) + ";";
		i = i + 1;
	}
	return out;
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

// ===== Writer =====
//
// Line format (tab-separated; \1.. prefixes keep the reader dumb):
//   T idx kind flags callConv typeName typeNamesCsv childrenCsv ret extra symIdx optionalFieldsCsv
//   N idx kind flags l c el ec typeIdx symIdx typeExprIdx typeExprsCsv paramLocsCsv typeArg variantSlot paramSymsCsv baseExprsCsv <payload...>
//   S idx kind state flags overloadIdx mutatedParams duVariantSlot
//     locLine locCol locEndLine locEndCol inScope
//     name modulePath nativeName builtinKind headerPath jsModulePath
//     typeIdx overloadsCsv staticCsv declIdx dpCsv disamb exportName
//   E methodName sourcePath isStatic scopeDepth symIdx
//   C converterSymIdx targetTypeIdx
//   P compilerFuncName symIdx
//   D includeDirectives
//   F compilerFlags
//   X compileDirectives

export function writePreludePack(key: string, stamp: string, ctx: CheckerContext): void {
	const _w0 = performance.now();
	if (packDisabled()) return;
	const root = packRoot();
	ensureDir(root);

	const syms: Symbol[] = [];
	const symIdx = new HashMap<Symbol, int32>();
	const types: Type[] = [];
	const typeIdx = new HashMap<Type, int32>();
	const nodes: Node[] = [];
	const nodeIdx = new HashMap<Node, int32>();
	const scopeSet = new HashSet<Symbol>();
	let symCursor: int32 = 0;
	let typeCursor: int32 = 0;
	let nodeCursor: int32 = 0;

	// Index at enqueue time so every later index read is guaranteed present
	// (no Maybe at write sites). Worklist instead of mutual recursion — nested
	// functions here cannot forward-reference each other.
	function enqSym(s: Symbol | null, inScope: boolean): void {
		if (s == null || symIdx.has(s)) return;
		symIdx.set(s, syms.length as int32);
		syms.push(s);
		if (inScope) scopeSet.add(s);
	}

	function enqType(t: Type | null): void {
		if (t == null || typeIdx.has(t)) return;
		typeIdx.set(t, types.length as int32);
		types.push(t);
	}

	function enqNode(n: Node | null): void {
		if (n == null || nodeIdx.has(n)) return;
		nodeIdx.set(n, nodes.length as int32);
		nodes.push(n);
	}

	// Maybe-unwrapping helpers: a ternary `cond ? map.get(k) : -1` leaks the
	// Maybe struct to C; a function with an if-block narrows properly.
	function idxSym(s: Symbol | null): int32 {
		if (s == null || !symIdx.has(s)) return -1;
		const v = symIdx.get(s);
		return v == null ? -1 : v;
	}

	function idxType(t: Type | null): int32 {
		if (t == null || !typeIdx.has(t)) return -1;
		const v = typeIdx.get(t);
		return v == null ? -1 : v;
	}

	function idxNode(n: Node | null): int32 {
		if (n == null || !nodeIdx.has(n)) return -1;
		const v = nodeIdx.get(n);
		return v == null ? -1 : v;
	}

	function idxs(arr: Node[] | null): string {
		if (arr == null) return "-";
		if (arr.length == 0) return "";
		let out = "";
		let i = 0;
		while (i < arr.length) {
			if (i > 0) out = out + ",";
			out = out + idxNode(arr[i]);
			i = i + 1;
		}
		return out;
	}

	// Enqueue every Node child of a node, per NodeData variant. Field order
	// mirrors the reader's buildNodeData — keep the two switches in sync.
	// Field-sink for the walk phase: only refs matter (enqNode assigns row
	// indexes; call order inside nodeFields defines the N-row ordering). All
	// value fields are ignored.
	const walkSink: FieldSink = {
		node: (name: string, x: Node | null): void => { enqNode(x); },
		nodes: (name: string, a: Node[] | null): void => { if (a != null) { for (const c of a) enqNode(c); } },
		nodesNested: (name: string, a: Node[][] | null): void => { if (a != null) { for (const row of a) { if (row != null) { for (const c of row) enqNode(c); } } } },
		typ: (name: string, t: Type | null): void => { enqType(t); },
		str: (name: string, s: string): void => {},
		strArr: (name: string, a: string[] | null): void => {},
		integer: (name: string, v: int64): void => {},
		float: (name: string, v: float64): void => {},
		bool: (name: string, b: boolean): void => {},
		loc: (name: string, l: SourceLocation | null): void => {},
		locs: (name: string, l: SourceLocation[] | null): void => {},
		floats: (name: string, a: number[] | null): void => {},
	};

	for (const s of ctx.table.current.symbols.values()) {
		enqSym(s, true);
	}
	// Extension methods can reference Symbol objects that are NOT the scope
	// symbols (registry entries hold their own sym identity — e.g. a specific
	// overload) — walk them into the closure or the pack emits ext.sym=null
	// and every extension call fails to match on load. Same for converter
	// payload types.
	if (ctx.extensionRegistry != null) {
		for (const ext of ctx.extensionRegistry.methods) {
			enqSym(ext.sym, false);
		}
	}
	for (const conv of ctx.converterTargetTypes.keys()) {
		enqSym(conv, false);
	}
	for (const ct of ctx.converterTargetTypes.values()) {
		enqType(ct);
	}
	for (const members of ctx.preludeInterf.values()) {
		for (const m of members) enqSym(m, false);
	}
	for (const members of ctx.preludeModuleScopes.values()) {
		for (const m of members) enqSym(m, false);
	}
	while (symCursor < syms.length || typeCursor < types.length || nodeCursor < nodes.length) {
		if (symCursor < syms.length) {
			const s = syms[symCursor];
			symCursor += 1;
			enqType(s.symbolType);
			for (const tp of s.typeParams) enqType(tp);
			if (s.overloads != null) {
				for (const ov of s.overloads) enqSym(ov, false);
			}
			if (s.staticOwner != null) enqSym(s.staticOwner, false);
			if (s.staticFields != null) {
				for (const sf of s.staticFields) enqSym(sf, false);
			}
			enqNode(s.declNode);
			for (const dp of s.defaultParams) enqNode(dp);
			continue;
		}
		if (nodeCursor < nodes.length) {
			const n = nodes[nodeCursor];
			nodeCursor += 1;
			enqType(n.nodeType);
			enqSym(n.resolvedSym, false);
			if (n.paramSyms != null) {
				for (const ps of n.paramSyms) enqSym(ps, false);
			}
			enqNode(n.typeExpr);
			if (n.typeExprs != null) {
				for (const te of n.typeExprs) enqNode(te);
			}
			if (n.baseExprs != null) {
				for (const be of n.baseExprs) enqNode(be);
			}
			nodeFields(n, walkSink);
			continue;
		}
		const t = types[typeCursor];
		typeCursor += 1;
		if (t.typeChildren != null) {
			for (const c of t.typeChildren) enqType(c);
		}
		enqType(t.typeReturn);
		enqType(t.typeExtra);
		enqSym(t.sym, false);
	}

	const packDebug = env.get("MSC_PACK_DEBUG") != "";
	if (packDebug) console.log(`[pack] closure syms=${syms.length} types=${types.length} nodes=${nodes.length} ms=${performance.now() - _w0}`);

	const lines: string[] = [];
	lines.push(PACK_MAGIC);
	lines.push(`V\t${stamp}`);

	for (let i = 0; i < types.length; i += 1) {
		const t = types[i];
		const children: int32[] = [];
		if (t.typeChildren != null) {
			for (const c of t.typeChildren) children.push(idxType(c));
		}
		const names: string[] = t.typeNames != null ? t.typeNames : [];
		const optional: string[] = t.optionalFields != null ? t.optionalFields : [];
		if (t.attachedOps != null) {
			for (const o of t.attachedOps) {
				if (o != null) throw new Error(`internal: prelude pack type '${t.typeName}' carries attached op '${o.name}', which exists only after lowering`);
			}
		}
		lines.push(`T\t${i}\t${t.kind as int32}\t${t.typeFlags as uint32}\t${t.typeValue}\t${t.callConv as int32}\t${escapeP(t.typeName)}\t${joinCsv(names)}\t${intsCsv(children)}\t${idxType(t.typeReturn)}\t${idxType(t.typeExtra)}\t${idxSym(t.sym)}\t${joinCsv(optional)}`);
	}

	_wnodeIdx = nodeIdx;
	_wtypeIdx = typeIdx;
	for (let i = 0; i < nodes.length; i += 1) {
		const n = nodes[i];
		const loc = n.location;
		const tes = n.typeExprs != null ? idxs(n.typeExprs) : "-";
		const bes = n.baseExprs != null ? idxs(n.baseExprs) : "-";
		const pls = locsCsv(n.paramLocations);
		let pss = "-";
		if (n.paramSyms != null) {
			const psi: int32[] = [];
			for (const ps of n.paramSyms) psi.push(idxSym(ps));
			pss = psi.length == 0 ? "" : intsCsv(psi);
		}
		lines.push(`N\t${i}\t${n.kind as int32}\t${n.flags as uint64}\t${loc.line}\t${loc.column}\t${loc.endLine}\t${loc.endColumn}\t${idxType(n.nodeType)}\t${idxSym(n.resolvedSym)}\t${idxNode(n.typeExpr)}\t${tes}\t${pls}\t${escapeP(n.typeArg)}\t${n.variantSlot}\t${pss}\t${bes}\t${emitNodePayloadViaSink(n)}`);
	}

	for (let i = 0; i < syms.length; i += 1) {
		const s = syms[i];
		const loc = s.location;
		const ovl: int32[] = [];
		if (s.overloads != null) {
			for (const ov of s.overloads) ovl.push(idxSym(ov));
		}
		const stf: int32[] = [];
		if (s.staticFields != null) {
			for (const sf of s.staticFields) stf.push(idxSym(sf));
		}
		const dp = idxs(s.defaultParams);
		const tps: int32[] = [];
		for (const tp of s.typeParams) tps.push(idxType(tp));
		lines.push(`S\t${i}\t${s.symbolKind as int32}\t${s.state as int32}\t${s.symFlags as uint32}\t${s.overloadIdx}\t${s.mutatedParams}\t${s.duVariantSlot}\t${loc !== null ? loc.line : 0}\t${loc !== null ? loc.column : 0}\t${loc !== null ? loc.endLine : 0}\t${loc !== null ? loc.endColumn : 0}\t${scopeSet.has(s) ? 1 : 0}\t${escapeP(s.name)}\t${escapeP(s.modulePath)}\t${escapeP(s.nativeName)}\t${escapeP(s.builtinKind)}\t${escapeP(s.headerPath)}\t${escapeP(s.jsModulePath)}\t${idxType(s.symbolType)}\t${intsCsv(ovl)}\t${intsCsv(stf)}\t${idxNode(s.declNode)}\t${dp}\t${s.disamb}\t${escapeP(s.exportName)}\t${idxSym(s.staticOwner)}\t${intsCsv(tps)}`);
	}

	const importIdx: int32[] = [];
	const interfIdx: int32[] = [];
	for (let i = 0; i < syms.length; i += 1) {
		if (ctx.importSet.has(syms[i])) importIdx.push(i as int32);
		if (ctx.interfSet.has(syms[i])) interfIdx.push(i as int32);
	}
	lines.push(`Y\t${intsCsv(importIdx)}`);
	lines.push(`W\t${intsCsv(interfIdx)}`);
	for (const id of ctx.table.current.symbols.keys()) {
		const scoped = ctx.table.current.symbols.get(id);
		const key = identName(ctx.table.identCache, id);
		if (scoped != null && key != scoped.name) lines.push(`K\t${escapeP(key)}\t${idxSym(scoped)}`);
	}

	if (ctx.extensionRegistry != null) {
		for (const ext of ctx.extensionRegistry.methods) {
			lines.push(`E\t${escapeP(ext.methodName)}\t${escapeP(ext.sourcePath)}\t${ext.isStatic ? 1 : 0}\t${ext.scopeDepth as int32}\t${idxSym(ext.sym)}`);
		}
	}

	for (const conv of ctx.converterTargetTypes.keys()) {
		lines.push(`C\t${idxSym(conv)}\t${idxType(ctx.converterTargetTypes.get(conv))}`);
	}

	for (const name of ctx.compilerFuncs.keys()) {
		const declared = ctx.compilerFuncs.get(name);
		if (declared == null) continue;
		lines.push(`P\t${escapeP(name)}\t${idxSym(declared)}`);
	}

	for (const spec of ctx.preludeInterf.keys()) {
		const members = ctx.preludeInterf.get(spec);
		if (members == null) continue;
		const idx: int32[] = [];
		for (const m of members) idx.push(idxSym(m));
		lines.push(`U\t${escapeP(spec)}\t${intsCsv(idx)}`);
	}
	for (const path of ctx.preludeModuleScopes.keys()) {
		const members = ctx.preludeModuleScopes.get(path);
		if (members == null) continue;
		const idx: int32[] = [];
		for (const m of members) idx.push(idxSym(m));
		lines.push(`M\t${escapeP(path)}\t${intsCsv(idx)}`);
	}
	for (const path of ctx.ownModules) lines.push(`O\t${escapeP(path)}`);

	lines.push(`D\t${escapeP(ctx.includeDirectives)}`);
	lines.push(`F\t${escapeP(ctx.compilerFlags)}`);
	lines.push(`X\t${escapeP(ctx.compileDirectives)}`);

	if (packDebug) console.log(`[pack] rows=${lines.length} joining at ms=${performance.now() - _w0}`);
	const blob = lines.join("\n");
	if (packDebug) console.log(`[pack] bytes=${blob.byteLength} at ms=${performance.now() - _w0}`);
	const okw = atomicWritePack(`${root}/${key}.pk`, blob);
	if (packDebug) console.log(`[pack] write ok=${okw ? 1 : 0} total ms=${performance.now() - _w0}`);
	collectStaleEntries(packBase(), nowSeconds());
	_writeMs = _writeMs + (performance.now() - _w0);
}

// Emit-phase sink: appends each field's serialized column. Byte-for-byte the
// same output the pre-sink emitNodePayload produced (join("\t") === the old
// template's \t separators) — verified by pack byte-identity.
let _payloadCols: string[] = [];

const emitSink: FieldSink = {
	node: (name: string, x: Node | null): void => { _payloadCols.push(`${idxNodeP(x)}`); },
	nodes: (name: string, a: Node[] | null): void => { _payloadCols.push(idxsP(a)); },
	nodesNested: (name: string, a: Node[][] | null): void => { _payloadCols.push(nestedIdxsP(a)); },
	typ: (name: string, t: Type | null): void => { _payloadCols.push(`${idxTypeP(t)}`); },
	str: (name: string, s: string): void => { _payloadCols.push(escapeP(s)); },
	strArr: (name: string, a: string[] | null): void => { _payloadCols.push(joinCsv(a != null ? a : [])); },
	integer: (name: string, v: int64): void => { _payloadCols.push(`${v}`); },
	float: (name: string, v: float64): void => { _payloadCols.push(`${v}`); },
	bool: (name: string, b: boolean): void => { _payloadCols.push(b ? "1" : "0"); },
	loc: (name: string, l: SourceLocation | null): void => { _payloadCols.push(locCsv4(l)); },
	locs: (name: string, l: SourceLocation[] | null): void => { _payloadCols.push(locsCsv(l)); },
	floats: (name: string, a: number[] | null): void => { _payloadCols.push(floatsCsv(a)); },
};

function emitNodePayloadViaSink(n: Node): string {
	_payloadCols = [];
	nodeFields(n, emitSink);
	return _payloadCols.join("\t");
}

// ===== Reader =====

// The pack is pure ASCII by construction (escapeP escapes every byte >= 0x80),
// so `indexOf`/`slice` take the runtime's ASCII fast paths — memcmp scan and
// byte-range copy. That invariant is load-bearing: on a non-ASCII string these
// are character-indexed and re-walk the UTF-8 from the start on every call,
// which makes scanning the 2 MB blob quadratic (it hung the loader outright).
function splitPackLines(s: string): string[] {
	const lines: string[] = [];
	let pos = 0;
	const n = s.length;
	while (pos < n) {
		const nl = s.indexOf("\n", pos);
		if (nl < 0) {
			lines.push(s.slice(pos, n));
			break;
		}
		if (nl > pos) lines.push(s.slice(pos, nl));
		pos = nl + 1;
	}
	return lines;
}

function splitTabs(line: string): string[] {
	const out: string[] = [];
	let pos = 0;
	const n = line.length;
	while (true) {
		const tab = line.indexOf("\t", pos);
		if (tab < 0) {
			out.push(line.slice(pos, n));
			break;
		}
		out.push(line.slice(pos, tab));
		pos = tab + 1;
	}
	return out;
}


// In-place reader for the T, N and S rows: fields are read as bytes at an offset, so a number
// allocates nothing and a string is sliced only where the loaded object stores it. A field that
// is not what its column holds sets `bad`, and the loader answers with a miss.
class PackReader {
	b: uint8[];
	s: string;
	pos: int32 = 0;
	rowStart: int32 = 0;
	last: int32 = 10;
	bad: boolean = false;

	constructor(s: string) {
		this.s = s;
		this.b = [...s.asBytes()];
	}
}

function fieldEnd(this r: PackReader): int32 {
	let i = r.pos;
	const n = r.b.length;
	while (i < n) {
		const c = r.b[i] as int32;
		if (c == 9 || c == 10) break;
		i += 1;
	}
	return i;
}

function finish(this r: PackReader, end: int32): void {
	if (end >= r.b.length) {
		r.last = 10;
		r.pos = end;
		return;
	}
	r.last = r.b[end] as int32;
	r.pos = end + 1;
}

// Returns the tag byte of the next row, or -1 at the end of the pack. Empty lines are skipped.
function startRow(this r: PackReader): int32 {
	const n = r.b.length;
	while (r.pos < n && r.b[r.pos] == 10) r.pos += 1;
	if (r.pos >= n) return -1;
	r.rowStart = r.pos;
	const tag = r.b[r.pos] as int32;
	r.pos += 1;
	r.last = 9;
	if (r.pos < n && r.b[r.pos] != 9 && r.b[r.pos] != 10) r.bad = true;
	r.finish(r.pos);
	return tag;
}

function endRow(this r: PackReader): void {
	while (r.last == 9) r.finish(r.fieldEnd());
}

// The whole row from its tag to the newline, for the rows the loader keeps as text.
function rowText(this r: PackReader): string {
	let stop = r.rowStart;
	while (stop < r.b.length && r.b[stop] != 10) stop += 1;
	const text = r.s.byteSlice(r.rowStart, stop);
	r.finish(stop);
	return text;
}

function skip(this r: PackReader): void {
	if (r.last != 9) {
		r.bad = true;
		return;
	}
	r.finish(r.fieldEnd());
}

function int(this r: PackReader): int64 {
	if (r.last != 9) {
		r.bad = true;
		return 0;
	}
	const n = r.b.length;
	let i = r.pos;
	const negative = i < n && r.b[i] == 45;
	if (negative) i += 1;
	const digits = i;
	const limit: uint64 = negative ? 9223372036854775808 : 9223372036854775807;
	let value: uint64 = 0;
	while (i < n) {
		const d = (r.b[i] as int32) - 48;
		if (d < 0 || d > 9) break;
		if (value > (limit - (d as uint64)) / 10) r.bad = true;
		else value = value * 10 + (d as uint64);
		i += 1;
	}
	if (i == digits || (i < n && r.b[i] != 9 && r.b[i] != 10)) r.bad = true;
	r.finish(i);
	if (!negative) return value as int64;
	return value == 0 ? 0 : -((value - 1) as int64) - 1;
}

function str(this r: PackReader): string {
	if (r.last != 9) {
		r.bad = true;
		return "";
	}
	const end = r.fieldEnd();
	const text = end > r.pos ? r.s.byteSlice(r.pos, end) : "";
	r.finish(end);
	return text;
}

// A field that is usually "-", read without a slice.
function dashOrStr(this r: PackReader): string {
	const n = r.b.length;
	if (r.last == 9 && r.pos < n && r.b[r.pos] == 45 && (r.pos + 1 == n || r.b[r.pos + 1] == 9 || r.b[r.pos + 1] == 10)) {
		r.finish(r.pos + 1);
		return "-";
	}
	return r.str();
}

// Same reading as parseIntsCsv: "-" and "" are the empty list, anything after a number is skipped.
function ints(this r: PackReader): int32[] {
	const out: int32[] = [];
	if (r.last != 9) {
		r.bad = true;
		return out;
	}
	const end = r.fieldEnd();
	let i = r.pos;
	if (end == i || (end == i + 1 && r.b[i] == 45)) {
		r.finish(end);
		return out;
	}
	while (i < end) {
		let neg = false;
		if (r.b[i] == 45) {
			neg = true;
			i += 1;
		}
		let v: int32 = 0;
		while (i < end) {
			const d = (r.b[i] as int32) - 48;
			if (d < 0 || d > 9) break;
			v = v * 10 + d;
			i += 1;
		}
		out.push(neg ? -v : v);
		i += 1;
	}
	r.finish(end);
	return out;
}

export function tryLoadPreludePack(key: string, stamp: string): CheckerContext | null {
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
	const loaded = tryLoadPreludePackBody(body);
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
	const lines = splitPackLines(body);
	let li = 1;
	while (li < lines.length) {
		const line = lines[li];
		li = li + 1;
		if (line.length == 0) continue;
		const f = splitTabs(line);
		const tag = f[0];
		if (tag == "G" && f.length >= 2) {
			snap.mods.push({ path: unescapeP(f[1]), imports: [] });
		} else if (tag == "I" && f.length >= 5 && snap.mods.length > 0) {
			snap.mods[snap.mods.length - 1].imports.push({
				sourcePath: unescapeP(f[1]),
				sourceSpecifier: unescapeP(f[2]),
				names: splitCsv(f[3]),
				aliases: splitCsv(f[4]),
			});
		} else if (tag == "R" && f.length >= 6) {
			snap.circulars.push({
				fromPath: unescapeP(f[1]),
				toPath: unescapeP(f[2]),
				cycle: splitCsv(f[3]),
				importLine: f[4].parseInt() as int32,
				importNames: splitCsv(f[5]),
			});
		} else {
			return null;
		}
	}
	if (snap.mods.length == 0) return null;
	return snap;
}

// idxs-convention parse: "-" = null, "0" = empty, else comma list of N idx.
// idxs-convention parse: "-"/"" = empty list; a bare "0" is a REAL one-element
// list [nodes[0]] — the empty marker is "" (writer idxs/idxsP), never "0".
// Digit accumulation straight off charCodeAt (O(1) on the ASCII pack).
function parseNodeIdxList(s: string, nodes: Node[]): (Node | null)[] {
	if (s == "-" || s == "") return [];
	const out: (Node | null)[] = [];
	let i = 0;
	const n = s.length;
	while (i < n) {
		let neg = false;
		if (s.charCodeAt(i) == 45) {
			neg = true;
			i = i + 1;
		}
		let v: int32 = 0;
		while (i < n) {
			const c = s.charCodeAt(i);
			if (c >= 48 && c <= 57) {
				v = v * 10 + (c - 48);
				i = i + 1;
				continue;
			}
			break;
		}
		const idx = neg ? -v : v;
		out.push(idx >= 0 && idx < nodes.length ? nodes[idx] : null);
		i = i + 1;
	}
	return out;
}

function parseNodeArr(s: string, nodes: Node[]): Node[] {
	const r = parseNodeIdxList(s, nodes);
	const out: Node[] = [];
	for (const n of r) out.push(n != null ? n : null as unknown as Node);
	return out;
}

function nd(i: int32, nodes: Node[]): Node | null {
	return i >= 0 && i < nodes.length ? nodes[i] : null;
}

function tp(i: int32, types: Type[]): Type | null {
	return i >= 0 && i < types.length ? types[i] : null;
}

function splitRows(s: string): string[] {
	const out: string[] = [];
	let cur = "";
	let i = 0;
	while (i < s.length) {
		const ch = s.charAt(i);
		if (ch == ";") {
			out.push(cur);
			cur = "";
		} else {
			cur = cur + ch;
		}
		i = i + 1;
	}
	return out;
}

function parseNestedNodeArrs(s: string, nodes: Node[]): Node[][] {
	if (s == "-" || s == "") return [];
	const parts = splitRows(s);
	const out: Node[][] = [];
	for (const p of parts) out.push(parseNodeArr(p, nodes));
	return out;
}

let _packMalformed = false;

// A decimal field of a node payload, read without a copy; anything else marks the pack malformed
// and the loader answers with a miss.
function decInt(s: string): int32 {
	const n = s.byteLength;
	let i = 0;
	const negative = n > 0 && s.byteAt(0) == 45;
	if (negative) i = 1;
	if (i == n || n - i > 10) {
		_packMalformed = true;
		return 0;
	}
	let v: int64 = 0;
	while (i < n) {
		const d = (s.byteAt(i) as int32) - 48;
		if (d < 0 || d > 9) {
			_packMalformed = true;
			return 0;
		}
		v = v * 10 + (d as int64);
		i += 1;
	}
	return (negative ? -v : v) as int32;
}

// Mirror of emitNodePayload — same kinds, same field order. `f` holds the
// payload fields of the N row (everything after the common header).
function buildNodeData(kind: NodeKind, f: string[], nodes: Node[], types: Type[]): NodeData {
	if (kind == NodeKind.NumberLiteral) return { value: f[1].parseFloat(), isFloat: f[0] == "1", intVal: f[2].parseInt(), outOfRangeText: unescapeP(f[3]), isBitPattern: f[4] == "1" } as NodeData;
	if (kind == NodeKind.StringLiteral) return { value: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.BooleanLiteral) return { boolValue: f[0] == "1" } as NodeData;
	if (kind == NodeKind.NullLiteral) return { nullPlaceholder: true } as NodeData;
	if (kind == NodeKind.BigIntLiteral) return { bigintValue: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.RegexLiteral) return { regexPattern: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.Identifier) return { name: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.BinaryExpr) return { operator: unescapeP(f[0]), left: nd(decInt(f[1]), nodes) as Node, right: nd(decInt(f[2]), nodes) as Node } as NodeData;
	if (kind == NodeKind.UnaryExpr) return { unaryOp: unescapeP(f[0]), operand: nd(decInt(f[1]), nodes) as Node } as NodeData;
	if (kind == NodeKind.UpdateExpr) return { updateOp: unescapeP(f[0]), updateArg: nd(decInt(f[1]), nodes) as Node, isPrefix: f[2] == "1" } as NodeData;
	if (kind == NodeKind.CallExpr) return { callee: nd(decInt(f[0]), nodes) as Node, arguments: parseNodeArr(f[1], nodes), isDirectCall: f[2] == "1", resolvedOverloadIdx: f[3].parseFloat() } as NodeData;
	if (kind == NodeKind.MemberExpr) return { object: nd(decInt(f[0]), nodes) as Node, property: unescapeP(f[1]), isOptional: f[2] == "1" } as NodeData;
	if (kind == NodeKind.ArrayAccess) return { array: nd(decInt(f[0]), nodes) as Node, index: nd(decInt(f[1]), nodes) as Node } as NodeData;
	if (kind == NodeKind.ObjectLiteral) return { properties: parseNodeArr(f[0], nodes), keys: splitCsv(f[1]), keyLocations: parseLocs(f[2]) } as NodeData;
	if (kind == NodeKind.ArrayLiteral) return { elements: parseNodeArr(f[0], nodes) } as NodeData;
	if (kind == NodeKind.ArrowFunction) return { arrowParams: splitCsv(f[0]), arrowParamTypes: splitCsv(f[1]), arrowBody: nd(decInt(f[2]), nodes) as Node, arrowFlags: unescapeP(f[3]), arrowReturnType: unescapeP(f[4]), arrowDefaults: parseNodeArr(f[5], nodes) } as NodeData;
	if (kind == NodeKind.FunctionExpr) return { funcExprParams: splitCsv(f[0]), funcExprParamTypes: splitCsv(f[1]), funcExprBody: nd(decInt(f[2]), nodes) as Node, funcExprFlags: unescapeP(f[3]), funcExprReturnType: unescapeP(f[4]) } as NodeData;
	if (kind == NodeKind.TypeAssertion) return { asExpr: nd(decInt(f[0]), nodes) as Node, asType: unescapeP(f[1]) } as NodeData;
	if (kind == NodeKind.ConditionalExpr) return { ternaryCondition: nd(decInt(f[0]), nodes) as Node, ternaryConsequent: nd(decInt(f[1]), nodes) as Node, ternaryAlternate: nd(decInt(f[2]), nodes) as Node } as NodeData;
	if (kind == NodeKind.SpreadExpr) return { spreadArg: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.NewExpr) return { newCallee: nd(decInt(f[0]), nodes) as Node, newArguments: parseNodeArr(f[1], nodes) } as NodeData;
	if (kind == NodeKind.TryExpr) return { tryArg: nd(decInt(f[0]), nodes) as Node, hasCatch: f[1] == "1", catchVal: nd(decInt(f[2]), nodes) as Node } as NodeData;
	if (kind == NodeKind.MatchExpr) return { matchDisc: nd(decInt(f[0]), nodes) as Node, matchCases: parseNodeArr(f[1], nodes) } as NodeData;
	if (kind == NodeKind.MatchCase) return { casePatterns: parseNodeArr(f[0], nodes), caseGuard: nd(decInt(f[1]), nodes) as Node, caseBody: nd(decInt(f[2]), nodes) as Node } as NodeData;
	if (kind == NodeKind.AwaitExpr) return { awaitArg: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.YieldExpr) return { yieldArg: nd(decInt(f[0]), nodes) as Node, isDelegate: f[1] == "1" } as NodeData;
	if (kind == NodeKind.MoveExpr) return { moveArg: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.OutExpr) return { outArg: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.SizeofExpr) return { sizeofType: unescapeP(f[0]), sizeofResolved: tp(decInt(f[1]), types) as Type } as NodeData;
	if (kind == NodeKind.HiddenStdConv || kind == NodeKind.HiddenSubConv) return { convExpr: nd(decInt(f[0]), nodes) as Node, convType: tp(decInt(f[1]), types) as Type } as NodeData;
	if (kind == NodeKind.HiddenDeref || kind == NodeKind.HiddenAddr) return { expr: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeAnnotation) return { annotationType: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.ArrayPattern) return { patternElements: parseNodeArr(f[0], nodes), hasRestElement: f[1] == "1", patternDefaults: parseNodeArr(f[2], nodes) } as NodeData;
	if (kind == NodeKind.ObjectPattern) return { patternProps: parseNodeArr(f[0], nodes), hasRestProp: f[1] == "1" } as NodeData;
	if (kind == NodeKind.ObjectPatternProp) return { propKey: unescapeP(f[0]), propAlias: nd(decInt(f[1]), nodes) as Node, propDefault: nd(decInt(f[2]), nodes) } as NodeData;
	if (kind == NodeKind.DestructuringDecl) return { destrPattern: nd(decInt(f[0]), nodes) as Node, destrInit: nd(decInt(f[1]), nodes) as Node, destrIsConst: f[2] == "1" } as NodeData;
	if (kind == NodeKind.VariableDecl) return { declName: unescapeP(f[0]), declType: unescapeP(f[1]), initializer: nd(decInt(f[2]), nodes) as Node, declKind: decInt(f[3]) as DeclKind, nameLocation: parseLoc(f[4]) } as NodeData;
	if (kind == NodeKind.IfStmt) return { condition: nd(decInt(f[0]), nodes) as Node, consequent: nd(decInt(f[1]), nodes) as Node, alternate: nd(decInt(f[2]), nodes) as Node } as NodeData;
	if (kind == NodeKind.WhileStmt) return { whileCondition: nd(decInt(f[0]), nodes) as Node, whileBody: nd(decInt(f[1]), nodes) as Node, whileLabel: unescapeP(f[2]) } as NodeData;
	if (kind == NodeKind.ForStmt) return { forInit: nd(decInt(f[0]), nodes) as Node, forCondition: nd(decInt(f[1]), nodes) as Node, forUpdate: nd(decInt(f[2]), nodes) as Node, forBody: nd(decInt(f[3]), nodes) as Node } as NodeData;
	if (kind == NodeKind.ForOfStmt) return { forOfBinding: unescapeP(f[0]), forOfIsConst: f[1] == "1", forOfIterable: nd(decInt(f[2]), nodes) as Node, forOfBody: nd(decInt(f[3]), nodes) as Node, forOfPattern: nd(decInt(f[4]), nodes) as Node, bindingLocation: parseLoc(f[5]) } as NodeData;
	if (kind == NodeKind.ForInStmt) return { forInBinding: unescapeP(f[0]), forInIsConst: f[1] == "1", forInObject: nd(decInt(f[2]), nodes) as Node, forInBody: nd(decInt(f[3]), nodes) as Node } as NodeData;
	if (kind == NodeKind.BlockStmt) return { statements: parseNodeArr(f[0], nodes) } as NodeData;
	if (kind == NodeKind.ExprStmt) return { expr: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.ReturnStmt) return { argument: nd(decInt(f[0]), nodes) } as NodeData;
	if (kind == NodeKind.BreakStmt) return { breakLabel: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.ContinueStmt) return { continueLabel: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.FunctionDecl) return { fnName: unescapeP(f[0]), params: splitCsv(f[1]), fnParamTypes: splitCsv(f[2]), fnBody: nd(decInt(f[3]), nodes) as Node, fnFlags: unescapeP(f[4]), fnReturnType: unescapeP(f[5]), fnDefaults: parseNodeArr(f[6], nodes), nativeName: unescapeP(f[7]), nameLocation: parseLoc(f[8]) } as NodeData;
	if (kind == NodeKind.DoWhileStmt) return { doBody: nd(decInt(f[0]), nodes) as Node, doCondition: nd(decInt(f[1]), nodes) as Node } as NodeData;
	if (kind == NodeKind.SwitchStmt) return { switchDisc: nd(decInt(f[0]), nodes) as Node, switchCases: parseNodeArr(f[1], nodes) } as NodeData;
	if (kind == NodeKind.SwitchCase) return { caseTests: parseNodeArr(f[0], nodes), caseStmts: parseNodeArr(f[1], nodes), isDefault: f[2] == "1" } as NodeData;
	if (kind == NodeKind.UnreachableStmt) return { unreachableMsg: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.MatchStmt) return { matchStmtDisc: nd(decInt(f[0]), nodes) as Node, matchStmtCases: parseNodeArr(f[1], nodes) } as NodeData;
	if (kind == NodeKind.ImportDecl) return { importNames: splitCsv(f[0]), importAliases: splitCsv(f[1]), importSource: unescapeP(f[2]), nameLocations: parseLocs(f[3]), importTypeNames: splitCsv(f[4]) } as NodeData;
	if (kind == NodeKind.ExportDecl) return { exportedDecl: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeAliasDecl) return { aliasName: unescapeP(f[0]), aliasType: unescapeP(f[1]), aliasIsDistinct: f[2] == "1", aliasGenericParams: unescapeP(f[3]), discriminantName: unescapeP(f[4]), discriminantType: unescapeP(f[5]), variantKeys: splitCsv(f[6]), variantTypes: splitCsv(f[7]), nameLocation: parseLoc(f[8]) } as NodeData;
	if (kind == NodeKind.EnumDecl) return { enumName: unescapeP(f[0]), enumMembers: splitCsv(f[1]), enumValues: parseFloatsCsv(f[2]), nameLocation: parseLoc(f[3]), memberLocations: parseLocs(f[4]), enumInits: parseNodeArr(f[5], nodes) } as NodeData;
	if (kind == NodeKind.InterfaceDecl || kind == NodeKind.StructDecl) return { interfaceName: unescapeP(f[0]), interfaceFields: splitCsv(f[1]), interfaceFieldTypes: splitCsv(f[2]), interfaceExtends: splitCsv(f[3]), nameLocation: parseLoc(f[4]), interfaceFieldVisibility: splitCsv(f[5]), interfaceFieldDecorators: parseNestedNodeArrs(f[6], nodes), interfaceOptionalFields: splitCsv(f[7]), nativeName: unescapeP(f[8]) } as NodeData;
	if (kind == NodeKind.ClassDecl) return { className: unescapeP(f[0]), classDisplayName: unescapeP(f[1]), classExtends: unescapeP(f[2]), classBody: parseNodeArr(f[3], nodes), nameLocation: parseLoc(f[4]), classImplements: splitCsv(f[5]) } as NodeData;
	if (kind == NodeKind.PropertyDecl) return { propName: unescapeP(f[0]), propType: unescapeP(f[1]), propIsStatic: f[2] == "1", propIsReadonly: f[3] == "1", propVisibility: unescapeP(f[4]), propInitializer: nd(decInt(f[5]), nodes) as Node } as NodeData;
	if (kind == NodeKind.MethodDecl) return { methodName: unescapeP(f[0]), methodParams: splitCsv(f[1]), methodParamTypes: splitCsv(f[2]), methodBody: nd(decInt(f[3]), nodes) as Node, methodIsStatic: f[4] == "1", methodFlags: unescapeP(f[5]), methodVisibility: unescapeP(f[6]), methodReturnType: unescapeP(f[7]), methodDefaults: parseNodeArr(f[8], nodes), nativeName: unescapeP(f[9]), nameLocation: parseLoc(f[10]) } as NodeData;
	if (kind == NodeKind.ConstructorDecl) return { ctorParams: splitCsv(f[0]), ctorParamTypes: splitCsv(f[1]), ctorBody: nd(decInt(f[2]), nodes) as Node, ctorDefaults: parseNodeArr(f[3], nodes), ctorVisibility: unescapeP(f[4]) } as NodeData;
	if (kind == NodeKind.ThrowStmt) return { throwArg: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.TryCatchStmt) return { tryBody: nd(decInt(f[0]), nodes) as Node, catchName: unescapeP(f[1]), catchBody: nd(decInt(f[2]), nodes) as Node, finallyBody: nd(decInt(f[3]), nodes) as Node, catchBindingLocation: parseLoc(f[4]), hasCatchClause: f[5] == "1" } as NodeData;
	if (kind == NodeKind.MacroInvocation) return { macroName: unescapeP(f[0]), macroArgs: parseNodeArr(f[1], nodes), macroHasParens: f.length > 2 && f[2] == "1" } as NodeData;
	if (kind == NodeKind.DecoratedDecl) return { decorators: parseNodeArr(f[0], nodes), decoratedNode: nd(decInt(f[1]), nodes) as Node } as NodeData;
	if (kind == NodeKind.DeferStmt) return { deferExpr: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.TestDecl) return { testName: unescapeP(f[0]), testBody: nd(decInt(f[1]), nodes) as Node } as NodeData;
	if (kind == NodeKind.AssertStmt) return { assertExpr: nd(decInt(f[0]), nodes) as Node, assertSource: unescapeP(f[1]), assertMessage: unescapeP(f[2]), assertMessageExpr: nd(decInt(f[3]), nodes) } as NodeData;
	if (kind == NodeKind.ExternDecl) return { externKind: decInt(f[0]) as ExternKind, externName: unescapeP(f[1]), nativeName: unescapeP(f[2]), externType: unescapeP(f[3]) } as NodeData;
	if (kind == NodeKind.MacroDecl) return { macroDeclName: unescapeP(f[0]), macroDeclParams: splitCsv(f[1]), macroDeclParamTypes: splitCsv(f[2]), macroDeclReturnType: unescapeP(f[3]), macroDeclBody: nd(decInt(f[4]), nodes) as Node } as NodeData;
	if (kind == NodeKind.QuoteExpr) return { quoteBody: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.ComptimeBlock) return { comptimeBody: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.TypeGeneric) return { typExprBase: nd(decInt(f[0]), nodes) as Node, typExprArgs: parseNodeArr(f[1], nodes) } as NodeData;
	if (kind == NodeKind.TypeArray) return { typExprElement: nd(decInt(f[0]), nodes) as Node, typExprSize: f[1].parseFloat() } as NodeData;
	if (kind == NodeKind.TypeUnion) return { typExprMembers: parseNodeArr(f[0], nodes), discFieldName: unescapeP(f[1]), variantKeys: splitCsv(f[2]), discKind: unescapeP(f[3]) } as NodeData;
	if (kind == NodeKind.TypeIntersection) return { typExprMembers: parseNodeArr(f[0], nodes) } as NodeData;
	if (kind == NodeKind.TypeFunction) return { typExprParams: parseNodeArr(f[0], nodes), typExprReturn: nd(decInt(f[1]), nodes) as Node, typExprParamNames: splitCsv(f[2]) } as NodeData;
	if (kind == NodeKind.TypeObject) return { typExprFieldNames: splitCsv(f[0]), typExprFieldTypes: parseNodeArr(f[1], nodes), typExprIndexKey: nd(decInt(f[2]), nodes) as Node, typExprIndexValue: nd(decInt(f[3]), nodes) as Node, typExprFieldDecorators: parseNestedNodeArrs(f[4], nodes), typExprTypeName: unescapeP(f[5]), typExprOptionalFields: splitCsv(f[6]) } as NodeData;
	if (kind == NodeKind.Program) return { programStmts: parseNodeArr(f[0], nodes) } as NodeData;
	if (kind == NodeKind.ActorDecl) return { actorName: unescapeP(f[0]), actorBody: parseNodeArr(f[1], nodes), nameLocation: parseLoc(f[2]) } as NodeData;
	if (kind == NodeKind.SpliceMany) return { spliceNodes: parseNodeArr(f[0], nodes) } as NodeData;
	if (kind == NodeKind.JSXElement) return { jsxTag: unescapeP(f[0]), jsxAttrs: parseNodeArr(f[1], nodes), jsxChildren: parseNodeArr(f[2], nodes), jsxSelfClosing: f[3] == "1" } as NodeData;
	if (kind == NodeKind.JSXFragment) return { jsxFragChildren: parseNodeArr(f[0], nodes) } as NodeData;
	if (kind == NodeKind.JSXText) return { jsxText: unescapeP(f[0]) } as NodeData;
	if (kind == NodeKind.JSXExpressionContainer) return { jsxExpr: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.JSXAttribute) return { jsxAttrName: unescapeP(f[0]), jsxAttrValue: nd(decInt(f[1]), nodes) as Node } as NodeData;
	if (kind == NodeKind.JSXSpreadAttribute) return { jsxSpreadArg: nd(decInt(f[0]), nodes) as Node } as NodeData;
	if (kind == NodeKind.ComputedProperty) return { computedKey: nd(decInt(f[0]), nodes) as Node, computedValue: nd(decInt(f[1]), nodes) as Node } as NodeData;
	return { nullPlaceholder: true } as NodeData;
}

function tryLoadPreludePackBody(body: string): CheckerContext | null {
	const packDebug = env.get("MSC_PACK_DEBUG") != "";
	_packMalformed = false;
	const _r0 = performance.now();
	const rd = new PackReader(body);
	rd.pos = rd.fieldEnd();
	if (rd.pos >= rd.b.length) return null;
	rd.pos += 1;
	if (packDebug) console.log(`[pack:r] reader ms=${performance.now() - _r0}`);

	const types: Type[] = [];
	const syms: Symbol[] = [];
	const nodes: Node[] = [];
	const typeChildrenIdx: int32[][] = [];
	const typeReturnIdx: int32[] = [];
	const typeExtraIdx: int32[] = [];
	const typeSymIdx: int32[] = [];
	const symTypeIdx: int32[] = [];
	const symOverloadIdx: int32[][] = [];
	const symStaticIdx: int32[][] = [];
	const symDeclIdx: int32[] = [];
	const symOwnerIdx: int32[] = [];
	const symTypeParamsIdx: int32[][] = [];
	const symDpRaw: string[] = [];
	const inScopeFlags: int32[] = [];
	const nodeTypeRef: int32[] = [];
	const nodeSymRef: int32[] = [];
	const nodeTeRef: int32[] = [];
	const nodeTesRaw: string[] = [];
	const nodeBesRaw: string[] = [];
	const nodePlsRaw: string[] = [];
	const nodePssRaw: string[] = [];
	const nodePayload: string[][] = [];
	const extRows: string[][] = [];
	const convRows: string[][] = [];
	const compilerFuncRows: string[][] = [];
	const interfRows: string[][] = [];
	const moduleScopeRows: string[][] = [];
	const ownModules: string[] = [];
	const aliasRows: string[][] = [];
	let importRow = "";
	let exportRow = "";
	let includeDirectives = "";
	let compilerFlags = "";
	let compileDirectives = "";

	while (true) {
		const tag = rd.startRow();
		if (tag < 0) break;
		if (rd.bad) return null;
		if (tag == 86) {
			rd.endRow();
		} else if (tag == 84) {
			rd.skip();
			const t = emptyType();
			t.kind = rd.int() as int32 as TypeKind;
			t.typeFlags = rd.int() as uint32 as BitSet<TypeFlag>;
			t.typeValue = rd.int() as int32;
			t.callConv = rd.int() as int32 as CallingConvention;
			t.typeName = unescapeP(rd.str());
			t.typeNames = splitCsv(rd.str());
			typeChildrenIdx.push(rd.ints());
			typeReturnIdx.push(rd.int() as int32);
			typeExtraIdx.push(rd.int() as int32);
			typeSymIdx.push(rd.int() as int32);
			const optional = rd.str();
			if (optional != "-") t.optionalFields = splitCsv(optional);
			t.attachedOps = [];
			types.push(t);
			rd.endRow();
		} else if (tag == 78) {
			rd.skip();
			const kind = rd.int() as int32 as NodeKind;
			const flags = rd.int() as uint64 as BitSet<NodeFlag>;
			const line = rd.int() as int32;
			const column = rd.int() as int32;
			const loc = makeLoc(line, column);
			loc.endLine = rd.int() as int32;
			loc.endColumn = rd.int() as int32;
			const n = createNodeAt(kind, { nullPlaceholder: true } as NodeData, loc);
			n.flags = flags;
			nodeTypeRef.push(rd.int() as int32);
			nodeSymRef.push(rd.int() as int32);
			nodeTeRef.push(rd.int() as int32);
			nodeTesRaw.push(rd.dashOrStr());
			nodePlsRaw.push(rd.dashOrStr());
			n.typeArg = unescapeP(rd.str());
			n.variantSlot = rd.int() as int32;
			nodePssRaw.push(rd.dashOrStr());
			nodeBesRaw.push(rd.dashOrStr());
			const payloadFields: string[] = [];
			while (rd.last == 9) payloadFields.push(rd.str());
			nodes.push(n);
			nodePayload.push(payloadFields);
		} else if (tag == 83) {
			rd.skip();
			const kind = rd.int() as int32 as SymbolKind;
			const state = rd.int() as int32 as SymbolState;
			const symFlags = rd.int() as uint32 as BitSet<SymbolFlag>;
			const overloadIdx = rd.int() as int32;
			const mutatedParams = rd.int() as int32;
			const duVariantSlot = rd.int() as int32;
			const l = rd.int() as int32;
			const c = rd.int() as int32;
			const el = rd.int() as int32;
			const ec = rd.int() as int32;
			inScopeFlags.push(rd.int() == 1 ? 1 : 0);
			const s = makeSymbolState(unescapeP(rd.str()), kind, null, false, SymbolState.Hollow);
			s.state = state;
			s.symFlags = symFlags;
			s.overloadIdx = overloadIdx;
			s.mutatedParams = mutatedParams;
			s.duVariantSlot = duVariantSlot;
			s.location = makeLoc(l, c);
			s.location.endLine = el;
			s.location.endColumn = ec;
			s.modulePath = unescapeP(rd.str());
			s.nativeName = unescapeP(rd.str());
			s.builtinKind = unescapeP(rd.str());
			s.headerPath = unescapeP(rd.str());
			s.jsModulePath = unescapeP(rd.str());
			symTypeIdx.push(rd.int() as int32);
			symOverloadIdx.push(rd.ints());
			symStaticIdx.push(rd.ints());
			symDeclIdx.push(rd.int() as int32);
			symDpRaw.push(rd.str());
			if (rd.last == 9) s.disamb = rd.int() as int32;
			if (rd.last == 9) s.exportName = unescapeP(rd.str());
			symOwnerIdx.push(rd.last == 9 ? rd.int() as int32 : -1);
			symTypeParamsIdx.push(rd.last == 9 ? rd.ints() : []);
			syms.push(s);
			rd.endRow();
		} else {
			const f = splitTabs(rd.rowText());
			if (f[0] == "E") {
				extRows.push(f);
			} else if (f[0] == "C") {
				convRows.push(f);
			} else if (f[0] == "P") {
				compilerFuncRows.push(f);
			} else if (f[0] == "U") {
				interfRows.push(f);
			} else if (f[0] == "M") {
				moduleScopeRows.push(f);
			} else if (f[0] == "O") {
				ownModules.push(unescapeP(f[1]));
			} else if (f[0] == "K") {
				aliasRows.push(f);
			} else if (f[0] == "Y") {
				importRow = f[1];
			} else if (f[0] == "W") {
				exportRow = f[1];
			} else if (f[0] == "D") {
				includeDirectives = unescapeP(f[1]);
			} else if (f[0] == "F") {
				compilerFlags = unescapeP(f[1]);
			} else if (f[0] == "X") {
				compileDirectives = unescapeP(f[1]);
			} else {
				return null;
			}
		}
		if (rd.bad) return null;
	}

	if (syms.length == 0) return null;
	if (packDebug) console.log(`[pack:r] rows parsed T=${types.length} N=${nodes.length} S=${syms.length} ms=${performance.now() - _r0}`);

	for (let i = 0; i < types.length; i += 1) {
		const t = types[i];
		const kids = typeChildrenIdx[i];
		const children: Type[] = [];
		for (const k of kids) {
			if (k < 0 || k >= types.length) return null;
			children.push(types[k]);
		}
		t.typeChildren = children;
		t.typeReturn = typeReturnIdx[i] >= 0 && typeReturnIdx[i] < types.length ? types[typeReturnIdx[i]] : null as unknown as Type;
		t.typeExtra = typeExtraIdx[i] >= 0 && typeExtraIdx[i] < types.length ? types[typeExtraIdx[i]] : null as unknown as Type;
		t.sym = typeSymIdx[i] >= 0 && typeSymIdx[i] < syms.length ? syms[typeSymIdx[i]] : null as unknown as Symbol;
	}

	for (let i = 0; i < syms.length; i += 1) {
		const s = syms[i];
		s.symbolType = symTypeIdx[i] >= 0 && symTypeIdx[i] < types.length ? types[symTypeIdx[i]] : null as unknown as Type;
		const ovls: Symbol[] = [];
		for (const k of symOverloadIdx[i]) {
			if (k < 0 || k >= syms.length) return null;
			ovls.push(syms[k]);
		}
		s.overloads = ovls;
		const stf: Symbol[] = [];
		for (const k of symStaticIdx[i]) {
			if (k < 0 || k >= syms.length) return null;
			stf.push(syms[k]);
		}
		s.staticFields = stf;
		const tps: Type[] = [];
		for (const k of symTypeParamsIdx[i]) {
			if (k < 0 || k >= types.length) return null;
			tps.push(types[k]);
		}
		s.typeParams = tps;
		s.staticOwner = symOwnerIdx[i] >= 0 && symOwnerIdx[i] < syms.length ? syms[symOwnerIdx[i]] : null;
		s.declNode = symDeclIdx[i] >= 0 && symDeclIdx[i] < nodes.length ? nodes[symDeclIdx[i]] : null as unknown as Node;
		s.defaultParams = parseNodeArr(symDpRaw[i], nodes);
	}
	if (packDebug) console.log(`[pack:r] T+S linked ms=${performance.now() - _r0}`);

	for (let i = 0; i < nodes.length; i += 1) {
		const n = nodes[i];
		n.nodeType = nodeTypeRef[i] >= 0 && nodeTypeRef[i] < types.length ? types[nodeTypeRef[i]] : null as unknown as Type;
		n.resolvedSym = nodeSymRef[i] >= 0 && nodeSymRef[i] < syms.length ? syms[nodeSymRef[i]] : null as unknown as Symbol;
		n.typeExpr = nd(nodeTeRef[i], nodes) as Node;
		n.typeExprs = nodeTesRaw[i] == "-" ? null : parseNodeArr(nodeTesRaw[i], nodes);
		n.baseExprs = nodeBesRaw[i] == "-" ? null : parseNodeArr(nodeBesRaw[i], nodes);
		n.paramLocations = nodePlsRaw[i] == "-" ? null : parseLocs(nodePlsRaw[i]);
		if (nodePssRaw[i] != "-") {
			const pss: Symbol[] = [];
			for (const k of parseIntsCsv(nodePssRaw[i])) {
				if (k < 0 || k >= syms.length) return null;
				pss.push(syms[k]);
			}
			n.paramSyms = pss;
		}
		n.data = buildNodeData(n.kind, nodePayload[i], nodes, types);
	}
	if (_packMalformed) return null;
	if (packDebug) console.log(`[pack:r] N linked ms=${performance.now() - _r0}`);

	const cache = createIdentCache();
	const ctx = createContextWithCache(cache);
	ctx.extensionRegistry = createExtensionRegistry();
	for (let i = 0; i < syms.length; i += 1) {
		const s = syms[i];
		s.nameId = getIdentId(cache, s.name);
		if (inScopeFlags[i] == 1) {
			(ctx.table.current.symbols as Map<int32, Symbol>).set(s.nameId, s);
		}
	}

	for (const f of aliasRows) {
		const si = f[2].parseInt() as int32;
		if (si >= 0 && si < syms.length) (ctx.table.current.symbols as Map<int32, Symbol>).set(getIdentId(cache, unescapeP(f[1])), syms[si]);
	}
	for (const si of parseIntsCsv(importRow)) {
		if (si >= 0 && si < syms.length) ctx.importSet.add(syms[si]);
	}
	for (const si of parseIntsCsv(exportRow)) {
		if (si < 0 || si >= syms.length) continue;
		ctx.interfSet.add(syms[si]);
		ctx.interf.push(syms[si]);
	}

	for (const f of extRows) {
		const symRef = f[5].parseInt() as int32;
		const extSym = symRef >= 0 && symRef < syms.length ? syms[symRef] : null as unknown as Symbol;
		const ext = createExtMethod(unescapeP(f[1]), unescapeP(f[2]), f[3] == "1", extSym, f[4].parseInt() as int32);
		registerExtension(ctx.extensionRegistry, ext);
	}

	for (const f of convRows) {
		const si = f[1].parseInt() as int32;
		const ti = f[2].parseInt() as int32;
		if (si >= 0 && si < syms.length && ti >= 0 && ti < types.length) ctx.converterTargetTypes.set(syms[si], types[ti]);
	}

	for (const f of compilerFuncRows) {
		const si = f[2].parseInt() as int32;
		if (si >= 0 && si < syms.length) ctx.compilerFuncs.set(unescapeP(f[1]), syms[si]);
	}
	for (const f of interfRows) {
		const members: Symbol[] = [];
		for (const si of parseIntsCsv(f[2])) {
			if (si >= 0 && si < syms.length) members.push(syms[si]);
		}
		ctx.preludeInterf.set(unescapeP(f[1]), members);
		for (const m of members) ctx.preludeExports.add(m);
	}
	for (const f of moduleScopeRows) {
		const members: Symbol[] = [];
		for (const si of parseIntsCsv(f[2])) {
			if (si >= 0 && si < syms.length) members.push(syms[si]);
		}
		ctx.preludeModuleScopes.set(unescapeP(f[1]), members);
	}
	for (const path of ownModules) ctx.ownModules.add(path);

	ctx.includeDirectives = includeDirectives;
	ctx.compilerFlags = compilerFlags;
	ctx.compileDirectives = compileDirectives;

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

test "preludePack: escape/unescape roundtrip incl separators" {
	const cases: string[] = ["", "plain", "with space", "tab\there", "line\nbreak", "comma,here", "back\\slash", "a\\nb\\tc,d\\e", "vietnamese:ttiếng Việt đũ ề"];
	for (const c of cases) {
		assert unescapeP(escapeP(c)) == c;
		assert splitCsv(joinCsv([c, c])).length == 2;
		assert splitCsv(joinCsv([c, c]))[0] == c;
	}
	assert joinCsv([]) == "-";
	assert splitCsv("-").length == 0;
	assert intsCsv([1, 2, 3]) == "1,2,3";
	assert (parseIntsCsv("4,5,6").length == 3) && parseIntsCsv("4,5,6")[2] == 6;
	assert parseIntsCsv("").length == 0;
	assert parseIntsCsv("0").length == 1 && parseIntsCsv("0")[0] == 0;
	assert parseIntsCsv("-1,-2").length == 2 && parseIntsCsv("-1,-2")[1] == -2;
	assert parseFloatsCsv("") != null && parseFloatsCsv("").length == 0;
	assert parseFloatsCsv("0").length == 1 && parseFloatsCsv("0")[0] == 0;
	// ASCII-forcing invariant: the escaped form must never carry a byte >= 0x80.
	const esc = escapeP("ttiếng Việt đũ ề");
	let maxByte = 0;
	let i = 0;
	while (i < esc.length) {
		const c = esc.charCodeAt(i);
		if (c > maxByte) maxByte = c;
		i = i + 1;
	}
	assert maxByte < 128;
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
		writePreludePack(key, PK_STAMP, ctx);
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
		assert loaded.extensionRegistry.methods.length == 1;
		assert loaded.extensionRegistry.methods[0].methodName == "pkExt";
		assert loaded.extensionRegistry.methods[0].sym == got;
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
		sym.declNode = createNodeAt(NodeKind.MacroDecl, { macroDeclName: "pkMacro", macroDeclParams: ["value"], macroDeclParamTypes: ["Node"], macroDeclReturnType: "Node", macroDeclBody: body } as NodeData, makeLoc(2, 1));
		const key = preludePackKey("macro-decl", ".test");
		writePreludePack(key, PK_STAMP, ctx);
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

test "preludePack: a generic type keeps its declared parameters and their constraints" {
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
		sym.typeParams = [t, k];
		const key = preludePackKey("type-params", ".test");
		writePreludePack(key, PK_STAMP, ctx);
		const loaded = tryLoadPreludePack(key, PK_STAMP);
		assert loaded != null;
		const got = loaded.table.current.symbols.get(getIdentId(loaded.table.identCache, "pkAt"));
		assert got != null;
		assert got.typeParams.length == 2;
		assert got.typeParams[0].typeName == "T" && got.typeParams[1].typeName == "K";
		const constraint = got.typeParams[1].typeExtra;
		assert constraint != null && constraint.kind == TypeKind.KeyOf;
		assert constraint.typeChildren[0] == got.typeParams[0];
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
		writePreludePack(key, PK_STAMP, ctx);
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
		writePreludePack(key, PK_STAMP, ctx);
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
		payload[18] = "q";
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
		writePreludePack(firstKey, firstStamp, pkCtxWithOneSym());
		_toolStamp = "compiler-b";
		secondKey = preludePackKey("stamp-probe", ".test");
		const secondStamp = preludePackStamp("stamp-probe");
		const second = pkCtxWithOneSym();
		const secondSym = second.table.current.symbols.get(getIdentId(second.table.identCache, "pkStampFn"));
		if (secondSym != null) secondSym.symbolType.kind = TypeKind.String;
		writePreludePack(secondKey, secondStamp, second);
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
		writePreludePack(key, PK_STAMP, pkCtxWithOneSym());
		assert tryLoadPreludePack(key, PK_STAMP) != null;
		const own = packRoot();
		for (const foreign of ["MSPK2", "MSPK9"]) {
			ensureDir(`${base}/${foreign}`);
			writeFile(`${base}/${foreign}/${key}.pk`, "another compiler's pack");
		}
		assert tryLoadPreludePack(key, PK_STAMP) != null;
		writePreludePack(key, PK_STAMP, pkCtxWithOneSym());
		assert exists(`${own}/${key}.pk`);
		for (const foreign of ["MSPK2", "MSPK9"]) {
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
