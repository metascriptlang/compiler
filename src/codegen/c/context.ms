// C Codegen — Context & Core Data Structures
//
// Follows Nim's cgendata.nim: section-based output, TLoc carrier, block stack.
// CGen = BModule, CProc = BProc, CBlock = TBlock, CLoc = TLoc.

import { Node, NodeKind } from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import { CheckerContext } from "../../checker/context";
import { sliceStr } from "../../utils/string";
import { check } from "std/testing";

// ===== CSection — C file output sections (Nim's TCFileSection) =====
// Final output concatenates in enum order.

export enum CSection {
	Headers,        // #include directives
	ForwardDecls,   // typedef struct Foo Foo;
	Types,          // full struct/enum/typedef definitions
	SeqTypes,       // sequence type structs (separate for ordering)
	ProcHeaders,    // function prototypes
	StringPool,     // string literal data
	GlobalVars,     // global variable declarations
	Procs,          // function bodies
	DatInit,        // data initialization (type info, static data — runs first)
	ModuleInit,     // module code initialization (user top-level code — runs second)
}

// ===== CProcSection — per-proc sections (Nim's TCProcSection) =====

export enum CProcSection {
	Locals,  // cpsLocals: variable declarations
	Init,    // cpsInit: initialization code
	Stmts,   // cpsStmts: statement code (the actual body)
}

// ===== CLocKind — expression result kind (Nim's TLocKind) =====

export enum CLocKind {
	None,      // free slot — callee fills it
	Temp,      // temporary variable (T1_, T2_, ...)
	LocalVar,  // local variable
	GlobalVar, // global variable
	Param,     // function parameter
	Field,     // struct field access
	Expr,      // arbitrary C expression
	Proc,      // procedure reference
	Data,      // constant data
}

// ===== CStorageLoc — where the value lives (Nim's TStorageLoc) =====

export enum CStorageLoc {
	Unknown,
	Stack,
	Heap,
	Static,
}

// ===== Builder — string accumulator (Nim's Builder) =====

export interface Builder {
	buf: string;
	indent: number;
}

export function createBuilder(): Builder {
	return { buf: "", indent: 0 };
}

export function add(b: Builder, s: string): void {
	b.buf = b.buf + s;
}

export function addNewline(b: Builder): void {
	b.buf = b.buf + "\n";
}

export function addIndent(b: Builder): void {
	for (let i = 0; i < b.indent; i += 1) {
		b.buf = b.buf + "  ";
	}
}

export function addLine(b: Builder, s: string): void {
	addIndent(b);
	add(b, s);
	addNewline(b);
}

export function extract(b: Builder): string {
	return b.buf;
}

// ===== CLoc — expression result carrier (Nim's TLoc) =====

export interface CLoc {
	kind: CLocKind;
	storage: CStorageLoc;
	snippet: string;       // C code fragment ("x", "a->b", "T1_")
	isIndirect: boolean;   // Nim's lfIndirect — backend introduced a pointer
	locType: Type;         // MetaScript type (for RC decisions, type mapping)
}

export function initLoc(kind: CLocKind, storage: CStorageLoc): CLoc {
	return {
		kind,
		storage,
		snippet: "",
		isIndirect: false,
		locType: null as unknown as Type,
	};
}

export function noLoc(): CLoc {
	return initLoc(CLocKind.None, CStorageLoc.Unknown);
}

// Read a CLoc — dereference if indirect
export function rdLoc(loc: CLoc): string {
	if (loc.isIndirect) return "(*" + loc.snippet + ")";
	return loc.snippet;
}

// Address of a CLoc
export function addrLoc(loc: CLoc): string {
	if (loc.isIndirect) return loc.snippet;
	return "(&" + loc.snippet + ")";
}

// ===== CBlock — nested scope (Nim's TBlock) =====

export interface CBlock {
	id: number;            // block label ID
	label: string;         // generated label text ("" if unused)
	locals: Builder;       // cpsLocals for this block
	init: Builder;         // cpsInit for this block
	stmts: Builder;        // cpsStmts for this block
	isLoop: boolean;
}

export function createBlock(id: number, isLoop: boolean): CBlock {
	return {
		id,
		label: "",
		locals: createBuilder(),
		init: createBuilder(),
		stmts: createBuilder(),
		isLoop,
	};
}

// ===== CProc — per-function state (Nim's BProc/TCProc) =====

export interface CProc {
	name: string;          // mangled C name
	returnType: Type;      // MetaScript return type
	isNrvo: boolean;       // true if function uses NRVO (out-param calling convention)
	labels: number;        // unique temp counter (T1_, T2_, ...)
	blocks: CBlock[];      // nested block stack (blocks[0] = top-level)
	breakIdx: number;      // which block a 'break' exits
	withinLoop: number;    // > 0 means inside a loop
	params: string[];      // parameter names (mangled)
	seenSinks: string[];   // tracks declared $sink_N_ temps (prevents duplicates)
}

export function createProc(name: string, returnType: Type): CProc {
	const topBlock = createBlock(0, false);
	const blocks: CBlock[] = [];
	blocks.push(topBlock);
	return {
		name,
		returnType,
		isNrvo: false,
		labels: 0,
		blocks,
		breakIdx: 0,
		withinLoop: 0,
		params: [],
		seenSinks: [],
	};
}

// Current block — top of the block stack (Nim's p.s(section))
export function currBlock(p: CProc): CBlock {
	return p.blocks[p.blocks.length - 1];
}

// Top-level proc block — block[0] (Nim's p.procSec(section))
export function procBlock(p: CProc): CBlock {
	return p.blocks[0];
}

// ===== Direct Emit Functions =====
// Builder is a value type — accessor functions return copies.
// These functions write DIRECTLY through p.blocks[idx] to avoid copies.

// Emit to current block's stmts
export function emitStmts(p: CProc, s: string): void {
	const idx = p.blocks.length - 1;
	p.blocks[idx].stmts.buf = p.blocks[idx].stmts.buf + s;
}

// Emit line to current block's stmts (with indent + newline)
export function emitStmtsLine(p: CProc, s: string): void {
	const idx = p.blocks.length - 1;
	let indent = "";
	for (let i = 0; i < p.blocks[idx].stmts.indent; i += 1) {
		indent = indent + "  ";
	}
	p.blocks[idx].stmts.buf = p.blocks[idx].stmts.buf + indent + s + "\n";
}

// Emit newline to current block's stmts
export function emitStmtsNl(p: CProc): void {
	const idx = p.blocks.length - 1;
	p.blocks[idx].stmts.buf = p.blocks[idx].stmts.buf + "\n";
}

// Get/set indent level of current block's stmts
export function getStmtsIndent(p: CProc): number {
	return p.blocks[p.blocks.length - 1].stmts.indent;
}

export function setStmtsIndent(p: CProc, indent: number): void {
	p.blocks[p.blocks.length - 1].stmts.indent = indent;
}

// Emit to proc-level (block[0]) locals
export function emitProcLocals(p: CProc, s: string): void {
	p.blocks[0].locals.buf = p.blocks[0].locals.buf + s;
}

export function emitProcLocalsLine(p: CProc, s: string): void {
	p.blocks[0].locals.buf = p.blocks[0].locals.buf + s + "\n";
}

// Read current block's stmts content
export function readStmts(p: CProc): string {
	return p.blocks[p.blocks.length - 1].stmts.buf;
}

// Read proc-level stmts content (block[0])
export function readProcStmts(p: CProc): string {
	return p.blocks[0].stmts.buf;
}

// Read proc-level locals content (block[0])
export function readProcLocals(p: CProc): string {
	return p.blocks[0].locals.buf;
}

// Legacy accessors — DEPRECATED, return copies (only for read)
export function pLocals(p: CProc): Builder {
	return currBlock(p).locals;
}

export function pInit(p: CProc): Builder {
	return currBlock(p).init;
}

export function pStmts(p: CProc): Builder {
	return currBlock(p).stmts;
}

export function pProcLocals(p: CProc): Builder {
	return procBlock(p).locals;
}

export function pProcInit(p: CProc): Builder {
	return procBlock(p).init;
}

export function pProcStmts(p: CProc): Builder {
	return procBlock(p).stmts;
}

// Push/pop blocks
export function pushBlock(p: CProc, isLoop: boolean): void {
	p.labels += 1;
	const block = createBlock(p.labels, isLoop);
	p.blocks.push(block);
	if (isLoop) p.withinLoop += 1;
}

export function popBlock(p: CProc): CBlock {
	const idx = p.blocks.length - 1;
	const blockLocals = p.blocks[idx].locals.buf;
	const blockInit = p.blocks[idx].init.buf;
	const blockStmts = p.blocks[idx].stmts.buf;
	const isLoop = p.blocks[idx].isLoop;
	p.blocks.pop();
	if (isLoop) p.withinLoop -= 1;
	// Merge block's sections into parent's stmts
	const parentIdx = p.blocks.length - 1;
	p.blocks[parentIdx].stmts.buf = p.blocks[parentIdx].stmts.buf + blockLocals + blockInit + blockStmts;
	// Return a placeholder (callers rarely use the return value)
	return p.blocks[parentIdx];
}

// ===== getTemp — allocate a temporary (Nim's getTemp) =====
// Declares in proc-level locals, returns a CLoc with the temp name.

export function getTemp(p: CProc, cType: string): CLoc {
	p.labels += 1;
	const name = "T" + p.labels + "_";
	emitProcLocalsLine(p, cType + " " + name + ";");
	const loc = initLoc(CLocKind.Temp, CStorageLoc.Stack);
	loc.snippet = name;
	return loc;
}

// ===== TypeCacheEntry — cached type mappings =====

export interface TypeCacheEntry {
	key: string;       // type signature key
	cTypeName: string; // generated C type name
}

export interface TypeCache {
	entries: TypeCacheEntry[];
}

export function createTypeCache(): TypeCache {
	return { entries: [] };
}

export function typeCacheGet(cache: TypeCache, key: string): string {
	for (let i = 0; i < cache.entries.length; i += 1) {
		if (cache.entries[i].key === key) return cache.entries[i].cTypeName;
	}
	return "";
}

export function typeCacheSet(cache: TypeCache, key: string, cTypeName: string): void {
	for (let i = 0; i < cache.entries.length; i += 1) {
		if (cache.entries[i].key === key) {
			cache.entries[i].cTypeName = cTypeName;
			return;
		}
	}
	const entry: TypeCacheEntry = { key, cTypeName };
	cache.entries.push(entry);
}

export function typeCacheHas(cache: TypeCache, key: string): boolean {
	return typeCacheGet(cache, key) !== "";
}

// ===== StringPoolEntry — interned string literals =====

export interface StringPoolEntry {
	value: string;
	cName: string;    // e.g., "TMP_STR_1"
}

export interface StringPool {
	entries: StringPoolEntry[];
	counter: number;
}

export function createStringPool(): StringPool {
	return { entries: [], counter: 0 };
}

// Intern a string — returns C name. Deduplicates.
export function internString(pool: StringPool, value: string): string {
	for (let i = 0; i < pool.entries.length; i += 1) {
		if (pool.entries[i].value === value) return pool.entries[i].cName;
	}
	pool.counter += 1;
	const cName = "TMP_STR_" + pool.counter;
	const entry: StringPoolEntry = { value, cName };
	pool.entries.push(entry);
	return cName;
}

// ===== NameSet — tracks already-declared names =====

export type NameSet = string[];

export function createNameSet(): NameSet {
	return [];
}

export function nameSetHas(ns: NameSet, name: string): boolean {
	for (let i = 0; i < ns.length; i += 1) {
		if (ns[i] === name) return true;
	}
	return false;
}

export function nameSetAdd(ns: NameSet, name: string): void {
	if (!nameSetHas(ns, name)) {
		ns.push(name);
	}
}

// ===== CGen — module-level state (Nim's BModule/TCGen) =====

export interface CGen {
	sections: Builder[];       // CSection enum-indexed (10 sections)
	currentProc: CProc;        // active proc being generated
	typeCache: TypeCache;      // fully-emitted types
	forwTypeCache: TypeCache;  // forward-declared types
	stringPool: StringPool;    // interned string literals
	declaredProcs: NameSet;    // prevents duplicate prototypes
	declaredThings: NameSet;   // prevents duplicate declarations
	knownEnumNames: NameSet;   // cross-module enum type names (for Member.Access → Member_Access)
	knownTypeNames: NameSet;   // cross-module type names (enums + structs, for TypeReference resolution)
	knownClassNames: NameSet;  // cross-module class names (need pointer semantics: Name*)
	checkerCtx: CheckerContext;
	modulePath: string;        // source file path (for module-qualified init names)
	labels: number;            // module-scope unique counter
}

export function createCGen(ctx: CheckerContext, modulePath: string): CGen {
	// Initialize all 10 sections
	const sections: Builder[] = [];
	for (let i = 0; i < 10; i += 1) {
		const b = createBuilder();
		sections.push(b);
	}
	return {
		sections,
		currentProc: null as unknown as CProc,
		typeCache: createTypeCache(),
		forwTypeCache: createTypeCache(),
		stringPool: createStringPool(),
		declaredProcs: createNameSet(),
		declaredThings: createNameSet(),
		knownEnumNames: createNameSet(),
		knownTypeNames: createNameSet(),
		knownClassNames: createNameSet(),
		checkerCtx: ctx,
		modulePath,
		labels: 0,
	};
}

// Section accessor by enum index
export function sec(g: CGen, s: CSection): Builder {
	return g.sections[s];
}

// Module-level temp name
export function moduleTemp(g: CGen): string {
	g.labels += 1;
	return "TM" + g.labels + "_";
}

// ===== Final Assembly — concatenate all sections =====

export function assembleOutput(g: CGen): string {
	let result = "";
	let needsSep = false;
	for (let i = 0; i < g.sections.length; i += 1) {
		const content = extract(g.sections[i]);
		if (content.length > 0) {
			if (needsSep) result = result + "\n";
			result = result + content;
			needsSep = true;
		}
	}
	return result;
}

// ===== Tests =====
test "add and extract" {
	const b = createBuilder();
	add(b, "hello");
	add(b, " world");
	check(extract(b) === "hello world");
}

test "addLine with indent" {
	const b = createBuilder();
	b.indent = 1;
	addLine(b, "int x;");
	check(extract(b) === "  int x;\n");
}

test "addLine no indent" {
	const b = createBuilder();
	addLine(b, "int x;");
	check(extract(b) === "int x;\n");
}

test "noLoc" {
	const loc = noLoc();
	check(loc.kind === CLocKind.None);
	check(loc.snippet === "");
}

test "initLoc" {
	const loc = initLoc(CLocKind.Temp, CStorageLoc.Stack);
	loc.snippet = "T1_";
	check(rdLoc(loc) === "T1_");
	check(addrLoc(loc) === "(&T1_)");
}

test "rdLoc indirect" {
	const loc = initLoc(CLocKind.Param, CStorageLoc.Stack);
	loc.snippet = "p";
	loc.isIndirect = true;
	check(rdLoc(loc) === "(*p)");
	check(addrLoc(loc) === "p");
}

test "create proc" {
	const p = createProc("test_fn", null as unknown as Type);
	check(p.name === "test_fn");
	check(p.labels === 0);
	check(p.blocks.length === 1);
}

test "getTemp" {
	const p = createProc("test_fn", null as unknown as Type);
	const t1 = getTemp(p, "int32_t");
	check(t1.snippet === "T1_");
	check(t1.kind === CLocKind.Temp);
	const t2 = getTemp(p, "double");
	check(t2.snippet === "T2_");
	const locals = readProcLocals(p);
	check(locals === "int32_t T1_;\ndouble T2_;\n");
}

test "push and pop block" {
	const p = createProc("test_fn", null as unknown as Type);
	pushBlock(p, true);
	check(p.blocks.length === 2);
	check(p.withinLoop === 1);
	emitStmts(p, "x = 1;");
	popBlock(p);
	check(p.blocks.length === 1);
	check(p.withinLoop === 0);
	const stmts = readProcStmts(p);
	check(stmts === "x = 1;");
}

test "nested blocks" {
	const p = createProc("test_fn", null as unknown as Type);
	emitStmts(p, "outer;\n");
	pushBlock(p, false);
	emitStmts(p, "inner;\n");
	popBlock(p);
	emitStmts(p, "after;\n");
	const stmts = readProcStmts(p);
	check(stmts === "outer;\ninner;\nafter;\n");
}

test "get miss" {
	const cache = createTypeCache();
	check(typeCacheGet(cache, "Foo") === "");
}

test "set and get" {
	const cache = createTypeCache();
	typeCacheSet(cache, "number", "double");
	check(typeCacheGet(cache, "number") === "double");
}

test "overwrite" {
	const cache = createTypeCache();
	typeCacheSet(cache, "x", "int");
	typeCacheSet(cache, "x", "int32_t");
	check(typeCacheGet(cache, "x") === "int32_t");
}

test "has" {
	const cache = createTypeCache();
	check(!typeCacheHas(cache, "x"));
	typeCacheSet(cache, "x", "int");
	check(typeCacheHas(cache, "x"));
}

test "intern new string" {
	const pool = createStringPool();
	const name = internString(pool, "hello");
	check(name === "TMP_STR_1");
}

test "deduplicate" {
	const pool = createStringPool();
	const n1 = internString(pool, "hello");
	const n2 = internString(pool, "hello");
	check(n1 === n2);
	check(pool.entries.length === 1);
}

test "different strings get different names" {
	const pool = createStringPool();
	const n1 = internString(pool, "hello");
	const n2 = internString(pool, "world");
	check(n1 === "TMP_STR_1");
	check(n2 === "TMP_STR_2");
	check(pool.entries.length === 2);
}

test "empty set" {
	const ns = createNameSet();
	check(!nameSetHas(ns, "x"));
}

test "add and check" {
	const ns = createNameSet();
	nameSetAdd(ns, "foo");
	check(nameSetHas(ns, "foo"));
	check(!nameSetHas(ns, "bar"));
}

test "no duplicates" {
	const ns = createNameSet();
	nameSetAdd(ns, "foo");
	nameSetAdd(ns, "foo");
	check(ns.length === 1);
}

test "create with 10 sections" {
	const g = createCGen(null as unknown as CheckerContext, "test");
	check(g.sections.length === 10);
}

test "section accessor" {
	const g = createCGen(null as unknown as CheckerContext, "test");
	add(sec(g, CSection.Headers), "#include <stdint.h>\n");
	add(sec(g, CSection.Procs), "void foo() {}\n");
	check(extract(sec(g, CSection.Headers)) === "#include <stdint.h>\n");
	check(extract(sec(g, CSection.Procs)) === "void foo() {}\n");
}

test "assembleOutput" {
	const g = createCGen(null as unknown as CheckerContext, "test");
	add(sec(g, CSection.Headers), "#include <stdint.h>\n");
	add(sec(g, CSection.Procs), "void foo() {}\n");
	const output = assembleOutput(g);
	check(output === "#include <stdint.h>\n\nvoid foo() {}\n");
}

test "moduleTemp" {
	const g = createCGen(null as unknown as CheckerContext, "test");
	const t1 = moduleTemp(g);
	const t2 = moduleTemp(g);
	check(t1 === "TM1_");
	check(t2 === "TM2_");
}
