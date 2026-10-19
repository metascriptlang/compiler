// Raiser eval — Full pipeline: parse → check → transform → codegen → execute
// Separate file to avoid import graph contamination in rgen.ms tests.


import { Node, Symbol, SymbolKind, SymbolState, createNode, NodeKind, ProgramData, FunctionDeclData, makeLoc } from "../../ast/node";
import { createUnifyBindings, unifyType } from "../../checker/types";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram, checkProgramWithRegistry, checkProgramWithRegistryCancellable, buildPreludeContext, registerSeedSymbols, clearSeedSymbols } from "../../checker/checkPass";
import { ExportRegistry, CheckerContext, CheckerError, CancelCtx, ExtensionMethod, Severity, addError, setEngineCheckMode, isPreludeExport } from "../../checker/context";
import { findModule } from "../../module/graph";
import { resolveRuntimeDir } from "../../utils/path";
import { join } from "std/fs/path";
import { writeStderr } from "std/io";
import { createTransformContextWithChecker } from "../../transform/context";
import { transformForRaiser } from "../../transform/raiserLowering";
import { RaiserValueKind, RaiserValue, heapObjectGetField, heapObjectGetString, heapStringText, heapStringLive, heapArrayLen, heapArrayGet, raiserConstString } from "../../raiser/value";
import { unboxFloat } from "../../raiser/marshal";
import { RaiserInstruction, raiserABC, RaiserOpcode, getSignedAx, branchOffset } from "../../raiser/bytecode";
import { disasmFunc, opName } from "../../raiser/disasm";
import { RaiserContext, createContext, load, execute } from "../../raiser/context";
import { RaiserVM, execModule, execLoop, createVM, vmReleaseHeaps } from "../../raiser/vm";
import { RaiserModule, RaiserFunction, createRaiserModule, createRaiserFunction, makeTestModule } from "../../raiser/module";
import { RaiserFuncMap, RaiserEnumMap, createFuncMap, registerRaiserOnDemand, isRoutineSym, takeRaiserCompileErrors, restoreRaiserCompileErrors } from "./context";
import { moduleScopeSymbols, enclosingTypeAliases, makeSymbolState, globalScope } from "../../checker/symbol";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { lookupModuleCtx, registerEngineBodyCtxFn } from "../../checker/instantiate";
import { synthToken } from "../../compiler/meta/bridge";
import { generateRaiser, appendProgramToImage } from "./rgen";
import { getComptimeOuterCtx, registerMacroEngineCompiler, EngineMacroResult, callComptimeHelperPreparer, registerMacroEvaluator, registerMacroCompiler, enterEngineCompile, leaveEngineCompile, engineCompiling } from "../../compiler/meta/callbacks";
import { ensureHostTableLoaded } from "../../compiler/meta/hostTable";
import { registerTypeQueryHostFns } from "../../compiler/meta/typeQuery";
import { callWithComptimeHostPolicy } from "../../compiler/meta/hostPolicy";

// --- Full Pipeline API ---

export function evalSourceFull(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) return createContext();
	return evalASTFull(parseResult.value);
}

// --- AST-based eval (no parsing step) ---
// Used by @comptime evaluation — takes a pre-built Program node.
//
// Spike 2: if the outer compile pipeline set the multi-module context
// (registry + graph + module + prelude), reuse it via checkProgramWithRegistry
// so cross-module imports inside the @comptime body resolve. Otherwise fall
// back to the single-file checkProgram path (used by direct tests).

// Macros always execute in the Raiser VM, so their std (string/array) methods must
// resolve to the .rms prelude (extern → host functions) regardless of the build
// target. The build target's prelude (e.g. .jms's pure-MS startsWith via asBytes)
// does not run in the VM. Cached — built once per process.
let _raiserPreludeCtx: CheckerContext | null = null;
let _raiserPreludeBuilding = false;
function raiserPreludeCtx(): CheckerContext {
	if (_raiserPreludeCtx == null) {
		const root = resolveRuntimeDir();
		const stdPath = root != "" ? join(root, "std") : "";
		_raiserPreludeBuilding = true;
		_raiserPreludeCtx = buildPreludeContext(stdPath, ".rms");
		_raiserPreludeBuilding = false;
	}
	return _raiserPreludeCtx;
}

let _lastEngineCheckErrors: CheckerError[] = [];


// On-demand helper compiles (ensureCompiledIntoEngine) run their own check pass
// whose errors belong to no wrapper. Without this queue a type-broken helper
// becomes garbage bytecode with no diagnostic (BUGS.md §2 row 9).
let _pendingHelperErrors: CheckerError[] = [];

// Check + transformForRaiser over a synthetic Program, ready for
// bytecode generation. Runs the inner pipeline destructively, so the caller must
// pass a Program whose real-module decls are CLONED (never the canonical nodes).
function transformForEngine(program: Node): Node {
	// Macro bodies dispatch string/array builtins through CallHost — the host
	// registry must be populated first (same as @comptime via evalComptimeBlock).
	ensureHostTableLoaded();
	registerTypeQueryHostFns();
	const outer = getComptimeOuterCtx();
	const savedOuterProgram = outer != null ? outer.program : null;
	const savedOuterPrelude = outer != null ? outer.preludeCtx : null as unknown as CheckerContext;
	const hasFullOuterCtx = outer != null
		&& outer.registry != null
		&& outer.graph != null
		&& outer.module != null
		&& outer.preludeCtx != null;
	const prevEngineMode = setEngineCheckMode(true);
	let transformed = program;
	try {
		const checkerCtx = hasFullOuterCtx
			? checkProgramWithRegistry(program, outer.registry, outer.graph, outer.module, raiserPreludeCtx())
			: checkProgram(program);
		_lastEngineCheckErrors = checkerCtx.errors;
		transformed = transformForRaiser(program, checkerCtx);
	} finally {
		setEngineCheckMode(prevEngineMode);
		if (outer != null) {
			outer.program = savedOuterProgram;
			outer.preludeCtx = savedOuterPrelude;
		}
	}
	return transformed;
}

export function evalASTCompile(program: Node): RaiserModule {
	return generateRaiser(transformForEngine(program));
}

export function evalASTFull(program: Node): RaiserContext {
	const transformed = transformForEngine(program);
	const ctx = createContext();
	for (const e of _lastEngineCheckErrors) {
		if (e.severity != Severity.Error) continue;
		ctx.lastError = e.message;
		return ctx;
	}
	load(ctx, generateRaiser(transformed));
	execute(ctx);
	return ctx;
}

// --- Comptime engine (Nim graph.vm + PCtx.code parity) ---
// ONE image + funcMap + persistent VM for the whole compilation. Each macro
// wrapper compiles ONCE into the shared image via appendProgramToImage (absolute
// funcIdx, no relocation); per invocation the caller marshals args into registers
// and re-enters through vmCallFunction. Scoped to one compilation by `token`.

interface ComptimeEngine {
	image: RaiserModule;
	funcMap: RaiserFuncMap;
	enumMap: RaiserEnumMap;
	vm: RaiserVM;
	bodyCtxs: HashMap<CheckerContext, CheckerContext>;
}

let _engine: ComptimeEngine = null as unknown as ComptimeEngine;
let _engineToken: CheckerContext = null as unknown as CheckerContext;

function freshEngine(): ComptimeEngine {
	// Seed with a never-called Halt entry so createVM has a valid entry frame;
	// macro functions append at index 1+.
	const entryCode: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const entryConsts: RaiserValue[] = [];
	const entryFn = createRaiserFunction("__engineEntry", entryCode, entryConsts, 0, 0, 2);
	const functions: RaiserFunction[] = [entryFn];
	const image = createRaiserModule("comptime-engine", functions, 0);
	const funcMap = createFuncMap();
	const enumMap: RaiserEnumMap = { items: [] };
	const vm = createVM(image, "arena");
	vm.printSink = (text: string): void => { writeStderr(text + "\n"); };
	const bodyCtxs = new HashMap<CheckerContext, CheckerContext>();
	return { image, funcMap, enumMap, vm, bodyCtxs };
}

function seedExtensionsOf(mc: CheckerContext, skip: Symbol | null): ExtensionMethod[] {
	const out: ExtensionMethod[] = [];
	if (mc.extensionRegistry == null) return out;
	if (mc.currentModule != null && mc.currentModule.stdPrelude) return out;
	const fromPrelude = new HashSet<Symbol>();
	if (mc.preludeCtx != null && mc.preludeCtx.extensionRegistry != null) {
		for (const p of mc.preludeCtx.extensionRegistry.methods) {
			if (p.sym != null) fromPrelude.add(p.sym);
		}
	}
	for (const m of mc.extensionRegistry.methods) {
		if (m.sym == null || m.sym == skip || fromPrelude.has(m.sym)) continue;
		out.push(m);
	}
	return out;
}

let _vmPreludeSyms: HashSet<Symbol> | null = null;
let _vmStdHelpers: HashSet<Symbol> | null = null;

function addWithOverloads(set: HashSet<Symbol>, s: Symbol): void {
	set.add(s);
	for (const o of s.overloads) set.add(o);
}

function isVmPreludeSym(sym: Symbol): boolean {
	if (_raiserPreludeBuilding) return false;
	if (_vmPreludeSyms == null) {
		const own = new HashSet<Symbol>();
		for (const s of globalScope(raiserPreludeCtx().table).symbols.values()) addWithOverloads(own, s);
		const exts = raiserPreludeCtx().extensionRegistry;
		if (exts != null) {
			for (const e of exts.methods) if (e.sym != null) own.add(e.sym);
		}
		_vmPreludeSyms = own;
	}
	const origin = sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
	return _vmPreludeSyms!.has(origin);
}

function isVmStdHelper(sym: Symbol): boolean {
	if (_raiserPreludeBuilding) return false;
	if (_vmStdHelpers == null) {
		const prelude = raiserPreludeCtx();
		const own = new HashSet<Symbol>();
		for (const scope of prelude.preludeModuleScopes.values()) {
			for (const s of scope) addWithOverloads(own, s);
		}
		if (prelude.extensionRegistry != null) {
			for (const ext of prelude.extensionRegistry.methods) {
				if (ext.sym != null) addWithOverloads(own, ext.sym!);
			}
		}
		_vmStdHelpers = own;
	}
	const origin = sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
	return _vmStdHelpers!.has(origin);
}

function engineBodyCtx(definingModulePath: string, owner: Symbol | null): CheckerContext | null {
	if (_engine == null || _raiserPreludeBuilding) return null;
	const outer = getComptimeOuterCtx();
	if (outer == null || outer.registry == null || outer.graph == null) return null;
	const mod = findModule(outer.graph, definingModulePath);
	if (mod == null) return null;
	if (mod.stdPrelude) return owner != null && isVmPreludeSym(owner) ? raiserPreludeCtx() : null;
	const declCtx = lookupModuleCtx(definingModulePath);
	if (declCtx == null) return null;
	const known = _engine.bodyCtxs.get(declCtx);
	if (known != null) return known;
	registerSeedSymbols(moduleScopeSymbols(declCtx.table), seedExtensionsOf(declCtx, null));
	const empty = createNode(NodeKind.Program, { programStmts: [] }, synthToken(makeLoc(1, 1)));
	const bodyCtx = checkProgramWithRegistryCancellable(empty, outer.registry, outer.graph, mod, raiserPreludeCtx(), null as unknown as CancelCtx, 0);
	clearSeedSymbols();
	_engine.bodyCtxs.set(declCtx, bodyCtx);
	return bodyCtx;
}

function vmStdSeeds(sym: Symbol): Symbol[] {
	const prelude = raiserPreludeCtx();
	const seeds: Symbol[] = [];
	const home = prelude.preludeModuleScopes.get(sym.modulePath);
	if (home != null) {
		for (const s of home) {
			if (s.name != sym.name) seeds.push(s);
		}
	}
	for (const s of globalScope(prelude.table).symbols.values()) {
		if (s.name != sym.name && !isPreludeExport(prelude, s)) seeds.push(s);
	}
	return seeds;
}

registerEngineBodyCtxFn(engineBodyCtx);

function compileProgramIntoEngine(program: Node, seeds: Symbol[], exts: ExtensionMethod[], wantFn: string, wantSym: Symbol | null = null): int32 {
	const previousOnDemand = registerRaiserOnDemand(ensureCompiledIntoEngine);
	defer registerRaiserOnDemand(previousOnDemand);
	enterEngineCompile();
	defer leaveEngineCompile();
	registerSeedSymbols(seeds, exts);
	const transformed = transformForEngine(program);
	clearSeedSymbols();
	// appendProgramToImage triggers on-demand helper compiles (ensureCompiledIntoEngine)
	// whose nested transformForEngine overwrites _lastEngineCheckErrors — restore this
	// program's own check errors so the caller reads them, not the last helper's (bug053).
	const ownErrors = _lastEngineCheckErrors;
	const idx = appendProgramToImage(_engine.image, _engine.funcMap, _engine.enumMap, transformed, wantFn, wantSym);
	_lastEngineCheckErrors = ownErrors;
	return idx;
}

const WIRE_ENUMS = ["NodeKind", "DeclKind", "ExternKind"];

function seedWireEnums(seeds: Symbol[]): void {
	let nodeSym: Symbol | null = null;
	for (const s of seeds) if (isMetaNodeSym(s)) nodeSym = s;
	if (nodeSym == null) return;
	const nodeCtx = lookupModuleCtx(nodeSym.modulePath);
	if (nodeCtx == null) return;
	for (const s of moduleScopeSymbols(nodeCtx.table)) {
		if (!WIRE_ENUMS.includes(s.name)) continue;
		let present = false;
		for (const t of seeds) if (t.name == s.name) present = true;
		if (!present) seeds.push(s);
	}
}

export function compileMacroIntoEngine(program: Node, token: CheckerContext, macroFnName: string, declCtx: CheckerContext): EngineMacroResult {
	return compileIntoEngineSeeded(program, token, macroFnName, declCtx, []);
}

function compileIntoEngineSeeded(program: Node, token: CheckerContext, macroFnName: string, declCtx: CheckerContext, leadSeeds: Symbol[]): EngineMacroResult {
	const nested = engineCompiling();
	if (_engineToken != token && !nested) {
		_engine = freshEngine();
		_engineToken = token;
	}
	const seeds: Symbol[] = [];
	for (const s of leadSeeds) seeds.push(s);
	for (const s of moduleScopeSymbols(declCtx.table)) seeds.push(s);
	const exts = seedExtensionsOf(declCtx, null);
	seedWireEnums(seeds);
	const outerHelperErrors = _pendingHelperErrors;
	_pendingHelperErrors = [];
	const outerCompileErrors = takeRaiserCompileErrors();
	const funcIdx = compileProgramIntoEngine(program, seeds, exts, macroFnName);
	const errors: CheckerError[] = [];
	for (const e of _lastEngineCheckErrors) errors.push(e);
	for (const e of _pendingHelperErrors) errors.push(e);
	for (const e of takeRaiserCompileErrors()) errors.push(e);
	_pendingHelperErrors = nested ? outerHelperErrors : [];
	if (nested) restoreRaiserCompileErrors(outerCompileErrors);
	return { vm: _engine.vm, funcIdx, errors };
}

registerMacroEngineCompiler(compileMacroIntoEngine);

function seedCtxForSym(sym: Symbol): CheckerContext {
	// A body ctx re-checking a generic instance carries the instantiating module's path over
	// the defining module's scope; a helper of the instantiating module takes that module's ctx.
	if (_engineToken != null) {
		const host = _engineToken.instantiatingCtx;
		if (host != null && host != _engineToken && sym.modulePath == host.modulePath) return host;
	}
	if (sym.modulePath != "" && _engineToken != null && sym.modulePath != _engineToken.modulePath) {
		const mc = lookupModuleCtx(sym.modulePath);
		if (mc != null) return mc;
	}
	if (_engineToken != null) return _engineToken;
	return null as unknown as CheckerContext;
}

function instanceTypeParamSeeds(sym: Symbol): Symbol[] {
	const seeds: Symbol[] = [];
	const generic = sym.instantiatedFrom;
	if (generic == null || generic.symbolType == null || sym.symbolType == null) return seeds;
	const bindings = createUnifyBindings();
	unifyType(generic.symbolType, sym.symbolType, bindings);
	for (let i = 0; i < bindings.names.length && i < bindings.types.length; i += 1) {
		seeds.push(makeSymbolState(bindings.names[i], SymbolKind.TypeAlias, bindings.types[i], false, SymbolState.Shaped));
	}
	return seeds;
}

function ensureCompiledIntoEngine(sym: Symbol): int32 {
	if (_engine == null) return -1;
	const isClass = sym.symbolKind == SymbolKind.Class;
	if (!isRoutineSym(sym) && !isClass) return -1;
	const name = isClass ? sym.name + "_new" : sym.name;
	const seenIdx = isClass ? _engine.funcMap.ctorIndices.get(sym) : _engine.funcMap.symbolIndices.get(sym);
	if (seenIdx != null) return seenIdx;
	if (sym.declNode == null) return -1;
	const seedCtx = seedCtxForSym(sym);
	const seeds: Symbol[] = instanceTypeParamSeeds(sym);
	let exts: ExtensionMethod[] = [];
	const homeOutsideBuild = lookupModuleCtx(sym.modulePath) == null;
	if (isVmPreludeSym(sym) || (homeOutsideBuild && isVmStdHelper(sym))) {
		for (const s of vmStdSeeds(sym)) seeds.push(s);
	} else if (seedCtx != null) {
		for (const s of moduleScopeSymbols(seedCtx.table)) {
			if (!isClass || s.name != sym.name) seeds.push(s);
		}
		exts = seedExtensionsOf(seedCtx, isClass ? sym : null);
	}
	const clone = cloneNodeForCheck(sym.declNode);
	let engineName = name;
	if (clone.kind == NodeKind.FunctionDecl) {
		engineName = "$comptime:helper";
		(clone.data as FunctionDeclData).fnName = engineName;
	}
	callComptimeHelperPreparer(clone);
	const decls: Node[] = [clone];
	const program = createNode(NodeKind.Program, { programStmts: decls }, synthToken(sym.declNode.location));
	const idx = compileProgramIntoEngine(program, seeds, exts, engineName, sym);
	for (const e of _lastEngineCheckErrors) {
		if (e.severity != Severity.Error) continue;
		_pendingHelperErrors.push({
			message: `helper '${name}': ${e.message}`,
			line: e.line, column: e.column, endLine: e.endLine, endColumn: e.endColumn,
			fatal: e.fatal, severity: e.severity, tags: e.tags,
		});
	}
	return idx;
}

export function releaseEngineHeaps(): void {
	if (_engine != null) vmReleaseHeaps(_engine.vm);
}

export function evalProgramViaEngine(program: Node, token: CheckerContext, fnName: string): RaiserContext {
	const result = compileIntoEngineSeeded(program, token, fnName, token, enclosingTypeAliases(token.table));
	if (result == null as unknown as EngineMacroResult) return createContext();
	let refused = false;
	if (result.errors != null) {
		for (const e of result.errors) {
			if (e.severity != Severity.Error) continue;
			addError(token, `@comptime block: ${e.message}`, e.line, e.column);
			refused = true;
		}
	}
	if (refused || result.funcIdx < 0) return createContext();
	const noArgs: RaiserValue[] = [];
	const resultVal = callWithComptimeHostPolicy(result.vm, result.funcIdx, noArgs, token.modulePath);
	if (result.vm.diagMessage != "") {
		const diagMsg = result.vm.diagMessage;
		result.vm.diagMessage = "";
		addError(token, `@comptime block: ${diagMsg}`, result.vm.diagLine as int32, result.vm.diagColumn as int32);
	}
	return {
		mod: result.vm.mod,
		hasModule: true,
		lastResult: resultVal,
		lastOutput: result.vm.output,
		arrayHeap: result.vm.arrayHeap,
		objectHeap: result.vm.objectHeap,
		lastError: result.vm.error,
		gcMode: result.vm.gcMode,
		orphanFailures: [],
	};
}

import { isMetaNodeSym } from "../../compiler/meta/nodeSym";
registerMacroEvaluator(evalASTFull);
registerMacroCompiler(evalASTCompile);

// --- Test helper ---

function evalFull(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		unreachable;
		return createContext();
	}
	return evalASTFull(parseResult.value);
}

function compileForOrc(code: string): RaiserModule {
	ensureHostTableLoaded();
	const parseResult = parseSource(code);
	if (!parseResult.ok) { unreachable; }
	const program = parseResult.value;
	const checkerCtx = checkProgram(program);
	const transformed = transformForRaiser(program, checkerCtx);
	return generateRaiser(transformed);
}

// Full pipeline under ORC (gcMode=orc) — returns the VM so heap state is inspectable.
function evalOrcVM(code: string): RaiserVM {
	return execModule(compileForOrc(code), "orc");
}

function evalArenaVM(code: string): RaiserVM {
	return execModule(compileForOrc(code), "arena");
}

test "engine: an enum converts to an integer type as its ordinal does, as on C and JS" {
	const decl = "enum E { Neg = -5, Big = 1000000000 } let e: E[] = [E.Neg, E.Big];";
	const ok = evalOrcVM(decl + " console.log(`${e[0] as uint8} ${e[0] as uint16} ${e[1] as uint8} ${e[0] as int64} ${e[1] as float64}`);");
	assert ok.error == "", ok.error;
	assert ok.output == "251 65531 0 -5 1000000000\n", ok.output;
	const narrow = evalOrcVM(decl + " console.log(`${e[1] as int16}`);");
	assert narrow.error.indexOf("value 1000000000 not in range -32768 .. 32767") >= 0, narrow.error;
}

test "engine: a value outside an enum's members stops the conversion into it" {
	const decl = "enum D { A, B, C } let i: int32[] = [3]; let z: float64[] = [0.0, 1.5];";
	const fromInt = evalOrcVM(decl + " console.log(`${i[0] as D}`);");
	assert fromInt.error.indexOf("value 3 not in range 0 .. 2") >= 0, fromInt.error;
	const fromNaN = evalOrcVM(decl + " console.log(`${(z[0] / z[0]) as D}`);");
	assert fromNaN.error.indexOf("value NaN not in range 0 .. 2") >= 0, fromNaN.error;
	const fromFloat = evalOrcVM(decl + " console.log(`${(z[1] as D) as int32}`);");
	assert fromFloat.error == "", fromFloat.error;
	assert fromFloat.output == "1\n", fromFloat.output;
}

test "engine: a uint64 past int64 converted into an enum stops with its unsigned value, as on C and JS" {
	const decl = "enum D { A, B, C } enum S { Neg = -5, Zero = 0, One = 1 }" +
		" let u: uint64[] = [9223372036854775808, 18446744073709551613, 1];";
	const past = evalOrcVM(decl + " console.log(`${(u[0] as D) as int32}`);");
	assert past.error.indexOf("value 9223372036854775808 not in range 0 .. 2") >= 0, past.error;
	const negative = evalOrcVM(decl + " console.log(`${(u[1] as S) as int32}`);");
	assert negative.error.indexOf("value 18446744073709551613 not in range -5 .. 1") >= 0, negative.error;
	const ok = evalOrcVM(decl + " console.log(`${(u[2] as D) as int32} ${(u[2] as S) as int32}`);");
	assert ok.error == "", ok.error;
	assert ok.output == "1 1\n", ok.output;
}

test "engine: a bigint is refused on the vm instead of carrying the number through" {
	const NO_BIGINT = "bigint is not supported on the Raiser VM";
	const cast = evalOrcVM("function u(v: uint64): uint64 { return v; } const b = u(18446744073709551615) as bigint; console.log(`${b}`);");
	assert cast.error.includes(NO_BIGINT), cast.error;
	assert cast.output == "", cast.output;
	const fromFloat = evalOrcVM("function f(v: float64): float64 { return v; } console.log(`${f(1.5) as bigint}`);");
	assert fromFloat.error.includes(NO_BIGINT), fromFloat.error;
	const literal = evalOrcVM("console.log(`${5n + 3n}`);");
	assert literal.error.includes(NO_BIGINT), literal.error;
	const comptime = evalSourceFull("function u(v: uint64): uint64 { return v; } const b = u(18446744073709551615) as bigint; return 1;");
	assert comptime.lastError.includes(NO_BIGINT), comptime.lastError;
}

test "engine: a conversion into char stops outside 0 .. 255 and truncates a float, as on C and JS" {
	const decl = "let a: int32[] = [-1, 300, 200]; let f: float64[] = [300.7, 65.9];";
	assert evalOrcVM(decl + " console.log(`${(a[0] as char) as int32}`);").error.indexOf("value -1 not in range 0 .. 255") >= 0;
	assert evalOrcVM(decl + " console.log(`${(a[1] as char) as int32}`);").error.indexOf("value 300 not in range 0 .. 255") >= 0;
	assert evalOrcVM(decl + " console.log(`${(f[0] as char) as int32}`);").error.indexOf("value 300.7 not in range 0 .. 255") >= 0;
	assert evalOrcVM(decl + " const c = a[2] as char; console.log(`${c as int8}`);").error.indexOf("value 200 not in range -128 .. 127") >= 0;
	const ok = evalOrcVM(decl + " const c = a[2] as char; console.log(`${(f[1] as char) as int32} ${c as int16} ${c as uint8}`);");
	assert ok.error == "", ok.error;
	assert ok.output == "65 200 200\n", ok.output;
}

test "engine: byteLength counts UTF-8 bytes independently from UTF-16 length" {
	const ctx = evalOrcVM("const value = 'é😀'; console.log(value.byteLength); console.log(value.length);");
	assert ctx.error == "";
	assert ctx.output == "6\n3\n";
}

test "engine: conditional return retains a fallthrough terminator" {
	const ctx = evalOrcVM("function emit(value: boolean): void { if (value) console.log('value'); else return; } emit(true); emit(false); console.log('end');");
	assert ctx.error == "";
	assert ctx.output == "value\nend\n";
}

test "engine: explicit exit coerces its number and aborts module initialization" {
	const ctx = evalOrcVM("console.log('before'); process.exit(7); console.log('after');");
	assert ctx.error == "";
	assert ctx.output == "before\n";
	assert ctx.exitValue.kind == RaiserValueKind.Int;
	assert ctx.exitValue.intVal == 7;
}

test "engine: exit inside a spawned strand ends the program with its code" {
	const ctx = evalOrcVM("function quit(): int32 { process.exit(3); return 0; }"
		+ " console.log('armed'); const f = spawn(() => quit());"
		+ " let n: int32 = 0; while (n < 1000) { n += 1; }"
		+ " console.log(`after ${await f}`);");
	assert ctx.error == "";
	assert ctx.output == "armed\n";
	assert ctx.exitValue.kind == RaiserValueKind.Int;
	assert ctx.exitValue.intVal == 3;
}

test "engine: for-of raises when its body changes the array length" {
	const ctx = evalOrcVM("function run(mode: int32): string { const arr: int32[] = [1, 2, 3]; let seen = ''; try { for (const x of arr) { seen = seen + String(x) + ','; if (seen.length > 20) break; if (mode == 0) arr.push(x); if (mode == 1 && x == 1) { arr.push(9); continue; } if (mode == 2) { arr.push(9); break; } } } catch (e) { return 'raised after ' + seen; } return 'finished ' + seen; }"
		+ " console.log(run(0)); console.log(run(1)); console.log(run(2)); console.log(run(3));");
	assert ctx.error == "";
	assert ctx.output == "raised after 1,\nraised after 1,\nfinished 1,\nfinished 1,2,3,\n";
}

test "engine: a for-of over a string yields its bytes as chars" {
	const ctx = evalOrcVM("let n = 0; let sum = 0; for (const c of 'h\u00e9llo') { n += 1; sum += c as int32; } console.log(n, sum);"
		+ " let s = 'ab'; let seen = ''; for (const c of s) { seen = seen + c + '|'; console.log(c); if (c as int32 == 97) continue; seen = seen + '!'; }"
		+ " console.log(seen); for (const c of 'xyz') { if (c as int32 == 121) break; console.log(`${c}`); }");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "6 795\na\nb\na|b|!\nx\n", ctx.output;
}

test "engine: a for-of over a generator runs it as a state machine" {
	const ctx = evalOrcVM("class Bag { items: int32[] = []; }"
		+ " function* toItems(this b: Bag): Iterator<int32> { for (const x of b.items) yield x; }"
		+ " function* toPairs(this b: Bag): Iterator<[string, int32]> { for (const x of b.items) { const p: [string, int32] = ['k' + x.toString(), x]; yield p; } }"
		+ " const b = new Bag(); b.items.push(4); b.items.push(5); b.items.push(6);"
		+ " for (const x of b) { if (x == 6) break; console.log(x); } for (const [k, v] of b) { if (v == 5) continue; console.log(k); }"
		+ " function* upTo(n: int32): Iterator<int32> { let i: int32 = 0; try { while (i < n) { yield i; i = i + 1; } } finally { console.log('done'); } }"
		+ " let sum: int32 = 0; for (const i of upTo(4)) { if (i == 1) continue; sum = sum + i; } console.log(sum);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "4\n5\nk4\nk6\ndone\n5\n", ctx.output;
}

test "engine: an object keeps its class, which instanceof and a checked conversion test" {
	const ctx = evalOrcVM("class A { a: int32 = 1; } class B extends A { b: int32 = 2; } class C extends B { } class D extends A { }"
		+ " const x: A = new C(); const d: A = new D(); const n: A | null = null; const u: unknown = new B();"
		+ " console.log(x instanceof B, x instanceof C, x instanceof D, d instanceof A, n instanceof A, u instanceof B, u instanceof C);"
		+ " console.log((x as B).b, (n as B | null) == null); console.log((d as B).b);");
	assert ctx.error == "invalid object conversion: D is not B", ctx.error;
	assert ctx.output == "true true false true false true false\n2 true\n", ctx.output;
}

test "engine: a for-of raises when the string it iterates changes length" {
	const ctx = evalOrcVM("let s = 'abc'; let seen = ''; try { for (const c of s) { seen = seen + c; s = s + 'd'; } } catch (e) { console.log('raised after ' + seen); }");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "raised after a\n", ctx.output;
}

test "engine: struct assignment preserves the source value" {
	const r = evalFull("struct S { x: int32; } let a: S = { x: 1 };"
		+ " let b = a; b.x = 2; return a.x * 10 + b.x;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 12;
}

test "engine: shared arrays copy their value elements" {
	const ctx = evalOrcVM("struct Item { value: int32; } const item: Item = { value: 1 }; const items: Item[] = [item]; items[0].value = 2; console.log(item.value); console.log(items[0].value);");
	assert ctx.error == "";
	assert ctx.output == "1\n2\n";
}

test "engine: recursive value copy plans preserve the source tree" {
	const ctx = evalOrcVM("struct Tree { value: int32; children: Vec<Tree>; } const tree: Tree = { value: 1, children: [{ value: 2, children: [] }] }; const copy = tree; copy.children[0].value = 3; console.log(tree.children[0].value); console.log(copy.children[0].value);");
	assert ctx.error == "";
	assert ctx.output == "2\n3\n";
}

test "engine: nested value copy retains reference identity under ORC" {
	const vm = evalOrcVM("interface R { x: int32; }"
		+ " struct S { child: Vec<int32>; shared: R; }"
		+ " let a: S = { child: [1], shared: { x: 1 } };"
		+ " let b = a; b.child.push(2); b.shared.x = 3;"
		+ " return a.child.length * 100 + b.child.length * 10 + a.shared.x;");
	assert vm.error == "";
	assert vm.exitValue.intVal == 123;
}

test "engine: value copy preserves Span fields and Span bindings" {
	const r = evalFull("struct S { view: Span<int32>; } function run(): int32 { let a: Vec<int32> = [1];"
		+ " let view: Span<int32> = a; let box: S = { view: a }; let copy = box;"
		+ " view[0] = 4; copy.view[0] = 7; return a[0]; } return run();");
	assert r.lastError == "";
	assert r.lastResult.intVal == 7;
}

test "engine: global initialization runs once and functions read its storage" {
	const r = evalFull("let calls: int32 = 0;"
		+ " function next(): int32 { calls += 1; return calls; }"
		+ " const first = next(); return calls * 100 + first * 10 + first;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 111;
}

test "engine: global updates retain prefix and postfix values" {
	const r = evalFull("let calls: int32 = 1;"
		+ " function next(): int32 { const before = calls++; const after = ++calls;"
		+ " return before * 10 + after; } return next() * 10 + calls;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 133;
}

test "engine: object spread copies owned fields and applies overrides" {
	const r = evalFull("struct S { x: int32; items: Vec<int32>; } let calls: int32 = 0;"
		+ " function source(): S { calls += 1; return { x: 1, items: [2] }; }"
		+ " const base = source(); let changed: S = { ...base, x: 3 };"
		+ " changed.items.push(4); return calls * 100 + base.items.length * 10 + changed.x;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 113;
}

test "engine: object spread evaluates a call operand once" {
	const r = evalFull("struct S { x: int32; y: int32; } let calls: int32 = 0;"
		+ " function source(): S { calls += 1; return { x: 1, y: 2 }; }"
		+ " const changed: S = { ...source(), x: 3 }; return calls * 10 + changed.x;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 13;
}

test "engine: array spread preserves source ownership" {
	const r = evalFull("const source: Vec<int32> = [1, 2];"
		+ " let extended: Vec<int32> = [...source, 3]; extended[0] = 9;"
		+ " return source[0] * 100 + source.length * 10 + extended.length;");
	assert r.lastError == "";
	assert r.lastResult.intVal == 123;
}

test "engine: a class field with no initializer holds its type's zero value" {
	const vm = evalOrcVM("struct Inner { x: int32; tag: string; }"
		+ " class Box { n: int32; f: float64; flag: boolean; name: string; items: Vec<int32>; inner: Inner; }"
		+ " const b = new Box();"
		+ " console.log(`${b.n} ${b.f} ${b.flag} [${b.name}] ${b.items.length} ${b.inner.x} [${b.inner.tag}]`);");
	assert vm.error == "";
	assert vm.output == "0 0 false [] 0 0 []\n";
}

test "engine: a method called inside a function binds its receiver as this" {
	const vm = evalOrcVM("class Reg { tag: string = \"reg\"; n: int32 = 3;"
		+ " echo(name: string): string { return this.tag + \":\" + name; }"
		+ " plain(): string { return this.tag; }"
		+ " bump(): int32 { this.n = this.n + 1; return this.n; } }"
		+ " function viaLocal(): string { const r = new Reg(); return r.echo(\"x\") + \" \" + r.plain(); }"
		+ " function viaParam(r: Reg): string { const b = r.bump(); return r.echo(\"y\") + \" \" + b.toString(); }"
		+ " function viaClosure(): string { const r = new Reg(); const inner = (): int32 => r.bump(); inner(); return inner().toString(); }"
		+ " const t = new Reg();"
		+ " console.log(`${t.echo(\"t\")} ${viaLocal()} ${viaParam(new Reg())} ${viaClosure()}`);");
	assert vm.error == "";
	assert vm.output == "reg:t reg:x reg reg:y 4 5\n";
}

test "engine: super runs the parent constructor and a call through the base runs the override" {
	const vm = evalOrcVM("class A { name: string; constructor(name: string) { this.name = name; }"
		+ " speak(n: int32): string { return this.name + \".\" + n.toString(); }"
		+ " intro(): string { return \"I \" + this.speak(1); } }"
		+ " class B extends A { speak(n: int32): string { return this.name + \"!\" + n.toString(); } }"
		+ " class C extends B { k: int32 = 4; constructor(name: string) { super(name + \"c\"); this.k = 5; } }"
		+ " function talk(a: A): string { return a.speak(2); }"
		+ " const all: A[] = [new A(\"a\"), new B(\"b\"), new C(\"x\")];"
		+ " for (const a of all) { console.log(`${talk(a)} ${a.intro()}`); }");
	assert vm.error == "";
	assert vm.output == "a.2 I a.1\nb!2 I b!1\nxc!2 I xc!1\n";
}

test "engine: the template of a method with its own type parameters is never compiled" {
	takeRaiserCompileErrors();
	const vm = evalOrcVM("class Owner { tag: string = \"o\";"
		+ " wrap<T>(v: T): () => T { return (): T => v; }"
		+ " unused<T>(v: T): int32 { const f = (): int32 => 1; const g = (): T => v; return f(); }"
		+ " both<A, B>(a: A, b: B): () => () => string { return (): () => string => { const inner = (): string => String(a) + String(b); return inner; }; }"
		+ " static count<T>(xs: T[]): () => int32 { return (): int32 => xs.length as int32; } }"
		+ " const o = new Owner();"
		+ " console.log(o.tag);");
	const warnings = takeRaiserCompileErrors();
	assert vm.error == "", vm.error;
	assert warnings.length == 0, warnings.length > 0 ? warnings[0].message : "";
	assert vm.output == "o\n", vm.output;
}

test "engine: new Array(n) holds n distinct zero elements" {
	const vm = evalOrcVM("struct E { h: int64; key: string; }"
		+ " let es: Vec<E> = new Array(3); es[2].h = 5;"
		+ " const ns = new Array<int32>(4);"
		+ " console.log(`${es.length} ${es[0].h} [${es[1].key}] ${es[2].h} ${ns.length} ${ns[3]}`);");
	assert vm.error == "";
	assert vm.output == "3 0 [] 5 4 0\n";
}

test "engine: a BitSet with no initializer holds its representation's zero in every width band" {
	const narrow = evalOrcVM("enum Small { A, B, C, D } let s: BitSet<Small>; return s;");
	assert narrow.error == "";
	assert narrow.exitValue.kind == RaiserValueKind.Int;
	assert narrow.exitValue.intVal == 0;
	const wide = evalOrcVM("enum Wide { A, B, C, D, E, F, G, H, I } class Holder { w: BitSet<Wide>; } return new Holder().w;");
	assert wide.error == "";
	assert wide.exitValue.kind == RaiserValueKind.Int;
	assert wide.exitValue.intVal == 0;
	let members = "";
	for (let i = 0; i < 70; i++) members = `${members}M${i}, `;
	const huge = evalOrcVM(`enum Huge { ${members} } enum Small { A, B, C, D }`
		+ " class Holder { s: BitSet<Small>; h: BitSet<Huge>; }"
		+ " let h: BitSet<Huge>; h = h | Huge.M69;"
		+ " const k = new Holder(); k.h = k.h | Huge.M3;"
		+ " console.log(`${h.has(Huge.M69) ? 1 : 0}${h.has(Huge.M0) ? 1 : 0}${k.h.has(Huge.M3) ? 1 : 0}${k.h.has(Huge.M69) ? 1 : 0}${k.s.has(Small.A) ? 1 : 0}`);");
	assert huge.error == "";
	assert huge.output == "10100\n";
}

test "engine: a local and a global declared without an initializer hold their type's zero value" {
	const vm = evalOrcVM("struct P { x: int32; } let g: int32;"
		+ " function f(): string { let n: int32; let t: string; let v: Vec<int32>; let p: P; return `${n} [${t}] ${v.length} ${p.x}`; }"
		+ " console.log(`${g} ${f()}`);");
	assert vm.error == "";
	assert vm.output == "0 0 [] 0 0\n";
}

test "engine: a struct literal that omits a field stores the field's zero value" {
	const vm = evalOrcVM("struct Inner { x: int32; }"
		+ " struct E { h: int64; v: int32; ok: boolean; tag: string; items: Vec<int32>; label: string | null; inner: Inner; }"
		+ " const e: E = { v: 1 };"
		+ " console.log(`${e.h} ${e.v} ${e.ok} [${e.tag}] ${e.items.length} ${e.label == null ? \"null\" : \"set\"} ${e.inner.x}`);");
	assert vm.error == "";
	assert vm.output == "0 1 false [] 0 null 0\n";
}

const RAISER_TIER_SLEEP = "@builtin(\"SleepAsync\") extern function nap(ms: number): Promise<void> from \"msSleepAsync\";";

test "engine: sleepAsync parks the strand for at least its delay" {
	const mod = compileForOrc(RAISER_TIER_SLEEP + " await nap(30); console.log(\"woke\");");
	const started = performance.now();
	const vm = execModule(mod, "orc");
	assert vm.error == "";
	assert vm.output == "woke\n";
	assert performance.now() - started >= 30;
}

test "engine: two sleepers wake in deadline order, not spawn order" {
	const vm = evalOrcVM(RAISER_TIER_SLEEP
		+ " const b = spawn(() => { await nap(2); console.log(\"b\"); return 1; });"
		+ " const a = spawn(() => { await nap(1); console.log(\"a\"); return 1; });"
		+ " const c = spawn(() => { let n: int32 = 0; while (n < 100000) { n += 1; } return 1; });"
		+ " const r = (await b) + (await a) + (await c); console.log(`done ${r}`);");
	assert vm.error == "";
	assert vm.output == "a\nb\ndone 3\n";
}

test "engine: awaiting a strand that sleeps is not a deadlock" {
	const vm = evalOrcVM(RAISER_TIER_SLEEP
		+ " const r = await spawn(() => { await nap(10); return 7; }); console.log(`${r}`);");
	assert vm.error == "";
	assert vm.output == "7\n";
}

test "engine: sleepAsync is refused in compile-time evaluation" {
	const r = evalFull(RAISER_TIER_SLEEP + " await nap(1); return 1;");
	assert r.lastError.includes("sleepAsync is not available in compile-time evaluation");
}

test "engine: shift left on int64 keeps bits past 31" {
	const r = evalSourceFull("function shl(one: int64, n: int64): int64 { return one << n; } return shl(1, 39);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 549755813888;
}

test "engine: shift left on int32 sign-extends at the type width" {
	const r = evalSourceFull("function shl(one: int32, n: int32): int32 { return one << n; } return shl(1, 31);");
	assert r.lastError == "";
	assert r.lastResult.intVal == -2147483648;
}

test "engine: shift count is taken modulo the type width" {
	const r = evalSourceFull("function shl(one: int32, n: int32): int32 { return one << n; } return shl(1, 39);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 128;
}

test "engine: shift left on uint32 masks to the type width" {
	const r = evalSourceFull("function shl(one: uint32, n: uint32): uint32 { return one << n; } return shl(3, 31);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 2147483648;
}

test "engine: bitwise NOT on uint8 stays in the byte" {
	const r = evalSourceFull("function inv(x: uint8): uint8 { return ~x; } return inv(5);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 250;
}

test "engine: shift right on uint64 is logical" {
	const r = evalSourceFull("function shl(one: uint64, n: uint64): uint64 { return one << n; } function shr(x: uint64, n: uint64): uint64 { return x >> n; } return shr(shl(1, 63), 63);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 1;
}

test "engine: shift right on uint32 is logical" {
	const r = evalSourceFull("function shr(x: uint32, n: uint32): uint32 { return x >> n; } return shr(2147483648, 31);");
	assert r.lastError == "";
	assert r.lastResult.intVal == 1;
}

test "engine: signed arithmetic in range reaches the type's bounds" {
	const ctx = evalOrcVM("function multiply(left: int16, right: int16): int16 { return left * right; }"
		+ " function negate(x: int8): int8 { return -x; } let a: int16 = 32766; a += 1; let b: int8 = -127; b--;"
		+ " let c: int32 = 2147483646; c++; let d: int64 = -9223372036854775807; d -= 1;"
		+ " console.log(`${multiply(181, 181)} ${multiply(-128, 256)} ${negate(-127)} ${a} ${b} ${c} ${d}`);");
	assert ctx.error == "";
	assert ctx.output == "32761 -32768 127 32767 -128 2147483647 -9223372036854775808\n";
}

test "engine: signed overflow stops at every width" {
	const programs = [
		"function multiply(left: int16, right: int16): int16 { return left * right; } console.log(`${multiply(300, 300)}`);",
		"function negate(x: int8): int8 { return -x; } console.log(`${negate(-128)}`);",
		"let a: int16 = 32767; a += 1; console.log(`${a}`);",
		"let b: int8 = 127; b++; console.log(`${b}`);",
		"function add(x: int32, y: int32): int32 { return x + y; } console.log(`${add(2147483647, 1)}`);",
		"function sub(x: int64, y: int64): int64 { return x - y; } console.log(`${sub(-9223372036854775807, 2)}`);",
		"function mul(x: int64, y: int64): int64 { return x * y; } console.log(`${mul(4294967296, 2147483648)}`);",
		"function neg(x: int64): int64 { return -x; } console.log(`${neg(-9223372036854775807 - 1)}`);",
		"function div(x: int8, y: int8): int8 { return x / y; } console.log(`${div(-128, -1)}`);",
	];
	for (const program of programs) {
		const ctx = evalOrcVM(program);
		assert ctx.error.indexOf("over- or underflow") >= 0, program;
		assert ctx.output == "", program;
	}
}

test "engine: a char step past 0 or 255 stops and one onto a bound is kept" {
	const programs = [
		"let c = 255 as char; c++; console.log(`${c as int32}`);",
		"let c = 255 as char; ++c; console.log(`${c as int32}`);",
		"let c = 0 as char; c--; console.log(`${c as int32}`);",
		"let c = 0 as char; --c; console.log(`${c as int32}`);",
	];
	for (const program of programs) {
		const ctx = evalOrcVM(program);
		assert ctx.error.indexOf("over- or underflow") >= 0, program;
		assert ctx.output == "", program;
	}
	const kept = evalOrcVM("let a = 254 as char; a++; let b = 1 as char; b--; console.log(`${a as int32} ${b as int32}`);");
	assert kept.error == "";
	assert kept.output == "255 0\n";
}

test "engine: unsigned arithmetic wraps at the type width" {
	const ctx = evalOrcVM("function mul(left: uint16, right: uint16): uint16 { return left * right; }"
		+ " function add(left: uint32, right: uint32): uint32 { return left + right; } let u: uint8 = 0; u -= 1;"
		+ " console.log(`${mul(300, 300)} ${add(4294967295, 1)} ${u}`);");
	assert ctx.error == "";
	assert ctx.output == "24464 0 255\n";
}

test "engine: an unsigned field or element update wraps at its type width; a signed one stops" {
	const ctx = evalOrcVM("struct Counter { n: uint8; } const c: Counter = { n: 255 }; c.n++; const xs: uint8[] = [255]; xs[0] += 2;"
		+ " console.log(`${c.n} ${xs[0]}`);");
	assert ctx.error == "";
	assert ctx.output == "0 1\n";
	const field = evalOrcVM("struct Counter { n: int8; } const c: Counter = { n: 127 }; c.n++; console.log(`${c.n}`);");
	assert field.error.indexOf("over- or underflow") >= 0;
	const element = evalOrcVM("const xs: int32[] = [2147483647]; xs[0] *= 2; console.log(`${xs[0]}`);");
	assert element.error.indexOf("over- or underflow") >= 0;
}

test "engine: compound assignment on a float local uses float arithmetic" {
	const ctx = evalOrcVM("let f: number = 1.5; f += 1.25; let h: float32 = 2.5; h *= 2.0;"
		+ " let d: float64 = 9.0; d /= 4.0; d -= 0.25; let m: number = 7.5; m %= 2.0;"
		+ " console.log(`${f} ${h} ${d} ${m}`);");
	assert ctx.error == "";
	assert ctx.output == "2.75 5 2 1.5\n";
}

test "engine: compound assignment on a float field, element or global uses float arithmetic" {
	const ctx = evalOrcVM("struct P { x: number; } let g: number = 10.5;"
		+ " function run(): void { let p: P = { x: 1.5 }; p.x += 0.25; const xs: number[] = [0.5]; xs[0] *= 3.0;"
		+ " g += 0.5; g -= 0.25; console.log(`${p.x} ${xs[0]} ${g}`); } run();");
	assert ctx.error == "";
	assert ctx.output == "1.75 1.5 10.75\n";
}

test "engine: a float32 rounds after every operation that produces one" {
	const ctx = evalOrcVM("let c: float32 = 16777216; c++; const old = c++; const a: float32 = 0.1;"
		+ " let b: float32 = a * 3; b += 0.7; function narrow(v: number): float32 { return v as float32; }"
		+ " const p: float32 = 0.1; const q: float32 = 10; const r: float32 = -1; const big: int64 = 1152921573326323713;"
		+ " console.log(`${c} ${old} ${a} ${b} ${narrow(0.1)} ${p * q + r} ${big as float32}`);");
	assert ctx.error == "";
	assert ctx.output == "16777216 16777216 0.10000000149011612 1 0.10000000149011612 0 1152921642045800400\n";
}

test "engine: a uint64 past int64 compares, divides and prints unsigned" {
	const ctx = evalOrcVM("function big(): uint64 { return 18446744073709551615; } function one(): uint64 { return 1; }"
		+ " const a = big(); const b = one(); let s = 'u='; s += a; let q = a; q /= 3; let m = a; m %= 7;"
		+ " console.log(`${b < a} ${a > b} ${a <= b} ${a >= b} ${a / 2} ${a % 10} ${a} ${a.toString()} ${a as number} ${a as float32} ${s} ${q} ${m}`);"
		+ " console.log(a);");
	assert ctx.error == "";
	assert ctx.output == "true true false true 9223372036854775807 5 18446744073709551615 18446744073709551615 18446744073709552000 18446744073709552000 u=18446744073709551615 6148914691236517205 1\n18446744073709551615\n";
}

test "engine: unsigned sums and products past 64 bits wrap as on C" {
	const ctx = evalOrcVM("function mul(a: uint64, b: uint64): uint64 { return a * b; }"
		+ " function add(a: uint64, b: uint64): uint64 { return a + b; }"
		+ " function sub(a: uint64, b: uint64): uint64 { return a - b; }"
		+ " function mul32(a: uint32, b: uint32): uint32 { return a * b; }"
		+ " const u = 0xFFFFFFFFFFFFFFFF as uint64; let k = u; k *= 5 as uint64;"
		+ " console.log(`${mul(u, 3 as uint64)} ${add(u, 2 as uint64)} ${sub(1 as uint64, 2 as uint64)}`"
		+ " + ` ${mul32(4000000000 as uint32, 4000000000 as uint32)} ${k}`);");
	assert ctx.error == "";
	assert ctx.output == "18446744073709551613 1 18446744073709551615 1983905792 18446744073709551611\n";
}

test "engine: increment and decrement on a float step by one" {
	const ctx = evalOrcVM("struct P { x: number; }"
		+ " function run(): void { let p: P = { x: 1.75 }; const xs: number[] = [1.5]; let k: number = 0.5;"
		+ " const before = k++; ++k; k--; p.x++; xs[0]--; console.log(`${before} ${k} ${p.x} ${xs[0]}`); } run();");
	assert ctx.error == "";
	assert ctx.output == "0.5 1.5 2.75 0.5\n";
}

test "engine: a number-typed length shrinks an array before a push" {
	const ctx = evalOrcVM("const a: number[] = [1, 2, 3, 4, 5]; const n: number = a.length; a.setLength(n - 1);"
		+ " const end: number = 3; const start: number = 1; a.setLength(a.length - (end - start)); a.push(9);"
		+ " const s: string[] = ['a', 'b', 'c', 'd']; const m: number = s.length; s.setLength(m - 1); s.push('z');"
		+ " console.log(`${a.length} ${a[0]} ${a[1]} ${a[2]} ${s.length} ${s[2]} ${s[3]}`);");
	assert ctx.error == "";
	assert ctx.output == "3 1 2 9 4 c z\n";
}

test "engine: a fractional number length truncates like the C backend" {
	const ctx = evalOrcVM("const a: number[] = [1, 2, 3, 4]; const n: number = 2.5; a.setLength(n); console.log(`${a.length}`);");
	assert ctx.error == "";
	assert ctx.output == "2\n";
}

test "engine: a not-null comparison yields a boolean" {
	const ctx = evalOrcVM("class Box { n: int32 = 1; } const item: Box | null = new Box(); const none: Box | null = null;"
		+ " const stored: boolean = item !== null; console.log(`${item !== null} ${none != null} ${stored}`);");
	assert ctx.error == "";
	assert ctx.output == "true false true\n";
}

test "engine: a predicate returning a not-null comparison yields a boolean" {
	const ctx = evalOrcVM("class Box { n: int32 = 1; } function isBox(value: unknown): value is Box { return value !== null; }"
		+ " function present(value: unknown): boolean { return value !== null; } const v = new Box() as unknown;"
		+ " console.log(`${isBox(v)} ${present(null)}`);");
	assert ctx.error == "";
	assert ctx.output == "true false\n";
}

test "engine: typeof over a nullable union names the variant the value holds" {
	const ctx = evalOrcVM("function kindOf(value: float32 | string | null): string { return typeof value; }"
		+ " function swapped(value: string | float32 | null): string { return typeof value; }"
		+ " console.log(`${kindOf('x')} ${kindOf(2.5)} ${kindOf(null)} ${swapped('x')} ${swapped(2.5)} ${swapped(null)}`);");
	assert ctx.error == "";
	assert ctx.output == "string number object string number object\n";
}

test "engine: a typeof guard selects the branch of the variant held" {
	const ctx = evalOrcVM("function show(value: int32 | string | boolean): string {"
		+ " if (typeof value === 'string') return 'text'; if (typeof value === 'boolean') return 'flag'; return 'count'; }"
		+ " console.log(`${show('50')} ${show(3)} ${show(true)}`);");
	assert ctx.error == "";
	assert ctx.output == "text count flag\n";
}

test "engine: typeof of a single-type operand is its static tag" {
	const ctx = evalOrcVM("const n: int32 = 4; const s = 'a' + 'b'; const b = n > 2;"
		+ " console.log(`${typeof n} ${typeof s} ${typeof b}`);");
	assert ctx.error == "";
	assert ctx.output == "number string boolean\n";
}

// The single-module engine links no prelude instance; the raiser corpus lane (663-666, stdValueEquality)
// runs the same comparisons program-wide.
test "engine: a struct == is a call to the std equality, not a by-reference compare" {
	const r = evalFull("struct Record { n: int32; text: string; }"
		+ " const a: Record = { n: 1, text: 'm' + 'n' }; const b: Record = { n: 1, text: 'm' + 'n' };"
		+ " return a == b ? 1 : 0;");
	assert r.lastError.indexOf("valueEquals", 0) >= 0;
}

test "engine: a tuple != is the negated std equality call" {
	const r = evalFull("const l: [int32, string] = [1, 'a' + 'b']; const q: [int32, string] = [1, 'a' + 'b']; return l != q ? 1 : 0;");
	assert r.lastError.indexOf("valueEquals", 0) >= 0;
}

test "engine: the hash builtins give the bits of the native 128-bit mix and float layout" {
	const ctx = evalOrcVM("@builtin(\"HiXorLo\") extern function hiXorLo(a: uint64, b: uint64): uint64;"
		+ " @builtin(\"Float64Bits\") extern function float64Bits(d: number): uint64;"
		+ " console.log(`${hiXorLo(0x123456789abcdef0 as uint64, 0xfedcba9876543210 as uint64)}`"
		+ " + ` ${hiXorLo(0xa0761d6478bd642f as uint64, 0xe7037ed1a0b428db as uint64)}`"
		+ " + ` ${hiXorLo(0xFFFFFFFFFFFFFFFF as uint64, 0xFFFFFFFFFFFFFFFF as uint64)}`"
		+ " + ` ${float64Bits(1.5)} ${float64Bits(-1.0)}`);");
	assert ctx.error == "";
	assert ctx.output == "3562955285811542818 2302960717771869484 18446744073709551615"
		+ " 4609434218613702656 13830554455654793216\n";
}

test "orc: correct result + no error on object program" {
	const vm = evalOrcVM("function mk(): { x: number } { return { x: 7 }; } const o = mk(); return o.x;");
	assert vm.error == "";
	assert unboxFloat(vm.exitValue) == 7;
}

test "orc: dead objects in loop are reclaimed (free-list grows)" {
	const vm = evalOrcVM("function mk(): { x: number } { return { x: 1 }; } let i = 0; let s = 0; while (i < 40) { const o = mk(); s = s + o.x; i = i + 1; } return s;");
	assert vm.error == "";
	assert unboxFloat(vm.exitValue) == 40;
	// arena would grow objectHeap ~40 with empty free-list; orc recycles dead objects
	assert vm.objectHeap.freeList.length > 0;
}

test "orc: heap stays bounded under long alloc loop" {
	const vm = evalOrcVM("function mk(): { x: number } { return { x: 1 }; } let i = 0; while (i < 500) { const o = mk(); i = i + 1; } return i;");
	assert vm.error == "";
	assert vm.exitValue.intVal == 500;
	// arena would grow objectHeap to ~500; orc recycles dead objects → bounded
	assert vm.objectHeap.objects.length < 50;
}

test "orc: reference cycles are collected (bounded heap)" {
	// each mkCycle leaks an a<->b cycle that pure ARC can never free; the cycle
	// collector must reclaim them so the heap stays bounded across 2000 iterations.
	const src = "interface CNode { next: CNode; } function mkCycle(): void { const a: CNode = { next: null as unknown as CNode }; const b: CNode = { next: null as unknown as CNode }; a.next = b; b.next = a; } let i = 0; while (i < 2000) { mkCycle(); i = i + 1; } return 0;";
	const vm = evalOrcVM(src);
	assert vm.error == "";
	// without cycle collection objectHeap would hold ~4000 leaked objects
	assert vm.objectHeap.objects.length < 1000;
}

test "orc: shared ref survives (stored in array)" {
	const vm = evalOrcVM("const a: number[] = []; let i = 0; while (i < 5) { a.push(i); i = i + 1; } let sum = 0; for (const v of a) { sum = sum + v; } return sum;");
	assert vm.error == "";
	assert unboxFloat(vm.exitValue) == 10;
}

// --- Phase 3 Integration Tests ---
// These tests verify features that require transforms to work.
test "match expression returns value" {
	const ctx = evalFull("const x = 2; return match (x) { 1 => 10, 2 => 20, _ => 0, };");
	assert ctx.lastResult.intVal == 20;
}

test "match with wildcard" {
	const ctx = evalFull("const x = 99; return match (x) { 1 => 10, _ => 42, };");
	assert ctx.lastResult.intVal == 42;
}

test "match on string" {
	const ctx = evalFull("const s = \"hello\"; return match (s) { \"hello\" => 1, \"world\" => 2, _ => 0, };");
	assert ctx.lastResult.intVal == 1;
}

test "match with when guard" {
	const ctx = evalFull("const x = 2; const flag = true; return match (x) { 2 when flag => 200, 2 => 20, _ => 0, };");
	assert ctx.lastResult.intVal == 200;
}

test "match when guard fails" {
	const ctx = evalFull("const x = 2; const flag = false; return match (x) { 2 when flag => 200, 2 => 20, _ => 0, };");
	assert ctx.lastResult.intVal == 20;
}

test "match simple wildcard default" {
	const ctx = evalFull("const x = 5; return match (x) { 1 => 10, _ => 42, };");
	assert ctx.lastResult.intVal == 42;
}

test "match guarded wildcard" {
	const ctx = evalFull("const x = 5; const flag = true; return match (x) { 1 => 10, _ when flag => 999, _ => 0, };");
	assert ctx.lastResult.intVal == 999;
}

test "existing arithmetic still works" {
	const ctx = evalFull("return 2 + 3 * 4;");
	assert ctx.lastResult.intVal == 14;
}

test "number toString through full pipeline" {
	const ctx = evalFull("return (10).toString() + \"-\" + (20).toString();");
	assert heapStringText(ctx.arrayHeap, ctx.lastResult) == "10-20";
}

// Enum member access through the FULL pipeline: the checker rewrites `Color.Green`
// → Identifier "Color_Green" before codegen. Without resolution of the
// mangled identifier the VM yields nil / 0 and match-on-enum collapses to arm 0.
test "enum member through full pipeline" {
	const ctx = evalFull("enum Color { Red, Green, Blue } return Color.Green as number;");
	assert ctx.lastResult.kind == RaiserValueKind.Float && ctx.lastResult.floatVal == 1.0;
}

test "enum explicit values through full pipeline" {
	const ctx = evalFull("enum Status { Active = 5, Inactive = 2, Pending = 9 } return Status.Pending as number;");
	assert ctx.lastResult.kind == RaiserValueKind.Float && ctx.lastResult.floatVal == 9.0;
}

test "match on enum through full pipeline" {
	const ctx = evalFull("enum Color { Red, Green, Blue } const c = Color.Blue; return match (c) { Color.Red => 10, Color.Green => 20, Color.Blue => 30, };");
	assert ctx.lastResult.intVal == 30;
}

test "function call through transform" {
	const ctx = evalFull("function add(a, b) { return a + b; } return add(10, 20);");
	assert ctx.lastResult.intVal == 30;
}

test "nested function call (full pipeline)" {
	const ctx = evalFull("function dbl(x) { return x * 2; } return dbl(dbl(3));");
	assert unboxFloat(ctx.lastResult) == 12;
}

test "objects through transform" {
	const ctx = evalFull("return { x: 42 };");
	assert ctx.lastResult.kind == RaiserValueKind.Object;
	const x = heapObjectGetField(ctx.objectHeap, ctx.lastResult.intVal, "x");
	assert x.intVal == 42;
}

test "build.ms pattern through transform" {
	const ctx = evalFull("interface Config { root: string; } function defineConfig(config: Config): Config { return config; } export default defineConfig({ root: \"src/main.ms\" });");
	assert ctx.lastResult.kind == RaiserValueKind.Object;
	const root = heapObjectGetString(ctx.arrayHeap, ctx.objectHeap, ctx.lastResult.intVal, "root");
	assert root == "src/main.ms";
}

test "sum 1..100" {
	const ctx = evalFull("function sum(n: number, acc: number): number { if (n <= 0) { return acc; } return sum(n - 1, acc + n); } return sum(100, 0);");
	assert unboxFloat(ctx.lastResult) == 5050;
}

test "arrow no captures" {
	const ctx = evalFull("const f = (x: number): number => x * 2; return f(21);");
	assert unboxFloat(ctx.lastResult) == 42;
}

test "arrow block body no captures" {
	const ctx = evalFull("const f = (a: number, b: number): number => { return a + b; }; return f(10, 20);");
	assert unboxFloat(ctx.lastResult) == 30;
}

test "arrow used in expression" {
	const ctx = evalFull("const dbl = (x: number): number => x * 2; return dbl(3) + dbl(4);");
	assert unboxFloat(ctx.lastResult) == 14;
}

test "arrow passed to function" {
	const ctx = evalFull("function apply(f: (x: number) => number, x: number): number { return f(x); } const dbl = (x: number): number => x * 2; return apply(dbl, 5);");
	assert unboxFloat(ctx.lastResult) == 10;
}

test "multiple arrows" {
	const ctx = evalFull("const add1 = (x: number): number => x + 1; const dbl = (x: number): number => x * 2; return dbl(add1(3));");
	assert unboxFloat(ctx.lastResult) == 8;
}

// --- Continue inside for-of / for-stmt — regression tests ---
// Pre-fix: ContinueStmt jumped to loopStart (before update step), so
// for-of skipped the increment → infinite loop. patchLoopContinues now
// patches each continue placeholder to the update emit point.
test "continue inside for-of advances index" {
	const ctx = evalFull("const arr = [1, 2, 3, 4, 5]; let sum = 0; for (const x of arr) { if (x === 3) continue; sum = sum + x; } return sum;");
	assert ctx.lastResult.intVal == 12;
}

test "continue inside C-style for runs update" {
	const ctx = evalFull("let sum = 0; for (let i = 0; i < 5; i = i + 1) { if (i === 2) continue; sum = sum + i; } return sum;");
	assert ctx.lastResult.intVal == 8;
}

test "continue inside while re-checks condition" {
	const ctx = evalFull("let i = 0; let sum = 0; while (i < 5) { i = i + 1; if (i === 3) continue; sum = sum + i; } return sum;");
	assert ctx.lastResult.intVal == 12;
}

// --- Nil identity check — kind-aware equality (regression) ---
// Pre-fix: `arr !== null` compiled to BneI64 which only checks intVal;
// Array(handle=0) and Nil both have intVal=0, so the comparison returned
// false-equal. IsKind opcode now performs kind-aware identity (mirrors Nim
// opcIsNil + HashLink OJNotNull).
test "first-allocated array compares correctly against null" {
	const ctx = evalFull("const arr = [1, 2]; return arr !== null ? 1 : 0;");
	assert ctx.lastResult.intVal == 1;
}

test "first-allocated object compares correctly against null" {
	const ctx = evalFull("const o = { x: 1 }; return o !== null ? 1 : 0;");
	assert ctx.lastResult.intVal == 1;
}

test "null === null is true" {
	const ctx = evalFull("return null === null ? 1 : 0;");
	assert ctx.lastResult.intVal == 1;
}

test "null === 0 is false (kind differs)" {
	const ctx = evalFull("return null === 0 ? 1 : 0;");
	assert ctx.lastResult.intVal == 0;
}

// --- Closure with captures ---

// Helper: parse → check → codegen → execute (no transforms)
function evalRaiserDirect(code: string): RaiserContext {
	const parseResult = parseSource(code);
	if (!parseResult.ok) {
		unreachable;
		return createContext();
	}
	checkProgram(parseResult.value);
	const mod = generateRaiser(parseResult.value);
	const ctx = createContext();
	load(ctx, mod);
	execute(ctx);
	return ctx;
}

test "a lambda-lifted closure reads a local it captured" {
	const ctx = evalFull("function make(): number { const x = 42; const f = (): number => x; return f(); } return make();");
	assert unboxFloat(ctx.lastResult) == 42;
}

test "a top-level closure reads a module binding" {
	const ctx = evalFull("const x = 99; const f = (): number => { return x; }; return f();");
	assert unboxFloat(ctx.lastResult) == 99;
}

test "a call through a local closure calls the closure, not a routine of the same name" {
	const ctx = evalFull("function add(a: number, b: number): number { return a - b; } function make(k: number): number { const add = (x: number): number => x + k; return add(1); } return make(10);");
	assert ctx.lastError == "", ctx.lastError;
	assert unboxFloat(ctx.lastResult) == 11;
}

test "a call through a closure parameter calls the closure, not a routine of the same name" {
	const ctx = evalFull("function add(a: number, b: number): number { return a - b; } function apply(add: (x: number) => number): number { return add(1); } return apply((x: number): number => x + 40);");
	assert ctx.lastError == "", ctx.lastError;
	assert unboxFloat(ctx.lastResult) == 41;
}

test "a closure made in a for-of reads the binding of its own iteration" {
	const ctx = evalFull("function make(): string { const fs: (() => string)[] = []; for (const j of ['a', 'b']) { fs.push((): string => j); } let out = ''; for (const f of fs) { out = out + f(); } return out; } return make();");
	assert ctx.lastError == "", ctx.lastError;
	assert heapStringText(ctx.arrayHeap, ctx.lastResult) == "ab";
}

test "a closure made in a for loop that continues reads the counter of its own iteration" {
	const ctx = evalFull("function make(): number { const fs: (() => number)[] = []; for (let i = 0; i < 6; i++) { if (i % 2 == 0) continue; fs.push((): number => i); } let acc: number = 0; for (const f of fs) { acc = acc * 10 + f(); } return acc; } return make();");
	assert ctx.lastError == "", ctx.lastError;
	assert unboxFloat(ctx.lastResult) == 135;
}

test "a function reads the global a module-level destructuring declares" {
	const ctx = evalFull("function pair(): number[] { return [3, 4]; } let [p, q] = pair(); const f = (): number => q; function sum(): number { return p * 10 + q; } q = 5; return sum() * 10 + f();");
	assert ctx.lastError == "", ctx.lastError;
	assert unboxFloat(ctx.lastResult) == 355;
}

test "hand-written closure pair (no transforms)" {
	const ctx = evalRaiserDirect("function lifted(_envP: unknown): number { return _envP.x; } const x = 99; const f = { fn: lifted, env: { x: x } }; return f();");
	assert ctx.lastResult.intVal == 99;
}

test "closure pair nested fn (no transforms)" {
	const ctx = evalRaiserDirect("function liftedFn(_envP: unknown): number { return _envP.x; } function make(): number { const x = 42; const f = { fn: liftedFn, env: { x: x } }; return f(); } return make();");
	assert ctx.lastResult.intVal == 42;
}

test "closure pair multi-field env (no transforms)" {
	const ctx = evalRaiserDirect("function liftedFn(_envP: unknown): number { return _envP.a + _envP.b; } const a = 10; const b = 32; const f = { fn: liftedFn, env: { a: a, b: b } }; return f();");
	assert ctx.lastResult.intVal == 42;
}

// Regression: chained MemberExpr through nested ObjectLiteral.
// Was broken because Raiser's resetTemps used locals.length, assuming locals
// pack at R[0..length-1] — but chained `t.nodeType.kind` allocates an
// intermediate temp at R1 (inner LoadField result) before declaring `k` at R2,
// leaving R1 as a non-local slot. Next stmt's allocReg returned R2, clobbering
// the local. Fix: nextReg = max(local.reg)+1 (context.ms resetTemps).
test "regression: chained MemberExpr through nested ObjectLiteral" {
	const ctx = evalFull(`
const t = { kind: 6, nodeType: { kind: 76, name: "Ref" } };
return t.nodeType.kind;
`);
	assert ctx.lastResult.intVal == 76;
}

test "regression: split MemberExpr through nested ObjectLiteral (control)" {
	const ctx = evalFull(`
const t = { kind: 6, nodeType: { kind: 76, name: "Ref" } };
const nt = t.nodeType;
return nt.kind;
`);
	assert ctx.lastResult.intVal == 76;
}

// Reproduces the original chained-vs-clobber scenario more precisely:
// declare `t` (R0), do chained `k = t.nodeType.kind` (R1 temp, R2=k local with
// R1 gap), then declare another local — pre-fix R2 was clobbered. Verifies
// k's value survives through the next statement.
test "regression: local at non-contiguous register survives next stmt" {
	const ctx = evalFull(`
const t = { kind: 6, nodeType: { kind: 76, name: "Ref" } };
const k = t.nodeType.kind;
const filler = "anything";
return k;
`);
	assert ctx.lastResult.intVal == 76;
}

// bug053 guard: the wrapper's own check errors must survive on-demand helper
// compiles. appendProgramToImage lazily compiles `helper` (a seed from the
// outer ctx) via ensureCompiledIntoEngine, whose nested transformForEngine
// used to overwrite _lastEngineCheckErrors before compileMacroIntoEngine
// read it — swallowing the wrapper's member error entirely.
test "engine: macro body errors survive on-demand helper compiles" {
	const outerPr = parseSource("export function helper(x: number): number { return x; }");
	assert outerPr.ok;
	const outerCtx = checkProgram(outerPr.value);
	const wrapperPr = parseSource(`
function __macroBody(t: string): number {
	const z = t.noSuchMemberAnywhere;
	return helper(1);
}
`);
	assert wrapperPr.ok;
	const r = compileMacroIntoEngine(wrapperPr.value, outerCtx, "__macroBody", outerCtx);
	let found = false;
	for (const e of r.errors) {
		if (e.message.indexOf("noSuchMemberAnywhere", 0) >= 0) found = true;
	}
	assert found;
}

test "engine: a slice is a view that writes through to its array" {
	const ctx = evalOrcVM("function bump(xs: Span<int32>): void { xs[0] += 100; }"
		+ " const a: int32[] = [1, 2, 3, 4]; bump(a[1..3]); bump(a[2...3]);"
		+ " const v: Span<int32> = a[1..4]; v[2] = 9; console.log(`${a[1]} ${a[2]} ${a[3]} ${v.length}`);");
	assert ctx.error == "";
	assert ctx.output == "102 103 9 3\n";
}

test "engine: a slice of a slice rebases onto the array" {
	const ctx = evalOrcVM("const a: int32[] = [1, 2, 3, 4, 5]; const v: Span<int32> = a[1..5];"
		+ " const w: Span<int32> = v[1..3]; w[0] = 30; console.log(`${a[2]} ${w.length} ${w[1]}`);");
	assert ctx.error == "";
	assert ctx.output == "30 2 4\n";
}

test "engine: a slice past the end stops with the slice error" {
	const ctx = evalOrcVM("const a: int32[] = [1, 2, 3, 4]; let e = 9; const v: Span<int32> = a[1..e]; console.log('unreachable');");
	assert ctx.error.contains("slice 1..9 out of bounds (length 4)");
	assert ctx.output == "";
}

test "engine: an empty slice passes at any start" {
	const ctx = evalOrcVM("const a: int32[] = [1, 2, 3, 4]; const v: Span<int32> = a[9..9]; console.log(`${v.length}`);");
	assert ctx.error == "";
	assert ctx.output == "0\n";
}

test "engine: a string span views its bytes" {
	const ctx = evalOrcVM("function n(v: Readonly<Span<char>>): int32 { let t = 0; for (let i = 0; i < v.length; i++) t += v[i] as int32; return t; }"
		+ " const s = 'hello'; console.log(`${n(s)} ${n(s[1..4])}`);");
	assert ctx.error == "";
	assert ctx.output == "532 317\n";
}

test "engine: String uses a struct's declared text conversion" {
	const ctx = evalFull("struct Label { text: string; } function toString(this x: Label): string { return 'label:' + x.text; } const x: Label = { text: 'hot' }; console.log(String(x));");
	assert ctx.lastError == "";
	assert ctx.lastOutput == "label:hot\n";
}

test "engine: String uses a class's declared text conversion and preserves primitive conversions" {
	const ctx = evalFull("class Name { text: string = 'node'; } function toString(this x: Name): string { return 'name:' + x.text; } console.log(String(new Name()), String(7), String(true), String('raw'));");
	assert ctx.lastError == "";
	assert ctx.lastOutput == "name:node 7 true raw\n";
}

test "engine: a byte view of a struct span traps instead of reading an element" {
	const ctx = evalOrcVM("struct P { a: uint32; } const ps: P[] = [{ a: 258 }]; const v: Span<P> = ps;"
		+ " const bytes = v as Ptr<void> as Ptr<uint8>; console.log(`${bytes[0]}`);");
	assert ctx.error.includes("on the Raiser VM: no byte representation"), ctx.error;
	assert ctx.output == "";
}

test "engine: a byte view through a typed pointer traps" {
	const ctx = evalOrcVM("struct P { a: uint32; } let p: P = { a: 258 }; const typed = p as Ptr<P>;"
		+ " const bytes = typed as Ptr<uint8>; console.log(`${bytes[0]}`);");
	assert ctx.error.includes("cannot convert Ptr<P> to Ptr<uint8> on the Raiser VM"), ctx.error;
	assert ctx.output == "";
}

test "engine: a same-element span pointer still reads its first element" {
	const ctx = evalOrcVM("struct P { a: uint32; } const ps: P[] = [{ a: 258 }]; const v: Span<P> = ps;"
		+ " const first = v as Ptr<P>; console.log(`${first[0].a}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "258\n";
}

test "engine: a span pointer reaches the struct element it addresses" {
	const ctx = evalOrcVM("struct P { a: uint32; } let ps: P[] = [{ a: 1 }, { a: 2 }]; const v: Span<P> = ps;"
		+ " const p = v as Ptr<P>; p.a = 9; console.log(`${ps[0].a} ${p[0].a} ${p[].a}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "9 9 9\n";
}

test "engine: an empty span has no element to point at" {
	const ctx = evalOrcVM("struct P { a: uint32; } const none: P[] = []; const v: Span<P> = none; const p = v as Ptr<P>; console.log('reached');");
	assert ctx.error.includes("out of bounds"), ctx.error;
	assert ctx.output == "";
}

test "engine: an empty span of pointers has no slot to point at" {
	const ctx = evalOrcVM("struct P { a: uint32; } const none: Ptr<P>[] = []; const v: Span<Ptr<P>> = none;"
		+ " const p = v as Ptr<Ptr<P>>; console.log('reached');");
	assert ctx.error.includes("out of bounds"), ctx.error;
	assert ctx.output == "";
}

test "engine: element pointers compare by identity" {
	const ctx = evalOrcVM("struct P { a: uint32; } let ps: P[] = [{ a: 1 }, { a: 2 }];"
		+ " const p = ps[1] as Ptr<P>; const q = ps[1] as Ptr<P>; const r = ps[0] as Ptr<P>; console.log(`${p == q} ${p == r}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "true false\n";
}

test "engine: a ref scalar parameter writes the caller's variable" {
	const ctx = evalOrcVM("function inc(ref n: int32): void { n = n + 1; n += 2; n++; } let k: int32 = 1; inc(k); console.log(`${k}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "5\n";
}

test "engine: an out parameter forwards to the caller's variable" {
	const ctx = evalOrcVM("function setInt(out v: int32, n: int32): void { v = n; } function forward(out v: int32, n: int32): void { setInt(v, n); }"
		+ " let a: int32 = 0; forward(a, 7); console.log(`${a}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "7\n";
}

test "engine: a ref string, element, field and class reference reach their storage" {
	const ctx = evalOrcVM("class Box { v: int32 = 1; } struct H { n: int32; }"
		+ " function shout(ref s: string): void { s += \"!\"; } function bump(ref v: int32): void { v++; }"
		+ " function swap(ref b: Box): void { b = new Box(); b.v = 9; }"
		+ " let t = \"hi\"; shout(t); let xs: int32[] = [1, 2]; bump(xs[1]); let h: H = { n: 4 }; bump(h.n);"
		+ " let box = new Box(); swap(box); console.log(`${t} ${xs[1]} ${h.n} ${box.v}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "hi! 3 5 9\n";
}

test "engine: a span pointer to a scalar is written through" {
	const ctx = evalOrcVM("let xs: int32[] = [1, 2]; const view: Span<int32> = xs; const p = view as Ptr<int32>; p[] = 5; p[0] += 2; console.log(`${xs[0]} ${p[]}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "7 7\n";
}

test "engine: an integer is not a typed pointer on the vm" {
	const ctx = evalOrcVM("let k: int32 = 1; const p = k as Ptr<int32>; console.log(`${p[]}`);");
	assert ctx.error.includes("cannot convert int32 to Ptr<int32> on the Raiser VM"), ctx.error;
	assert ctx.output == "";
}

test "engine: scalar pointers compare by location" {
	const ctx = evalOrcVM("let xs: int32[] = [1, 2, 3];"
		+ " const a = xs[0..2] as Ptr<int32>; const b = xs[1..3] as Ptr<int32>; const c = xs[0..1] as Ptr<int32>; const d = xs[1..2] as Ptr<int32>;"
		+ " console.log(`${a == b} ${a == c} ${b == d} ${a != b}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "false true true true\n";
}

test "engine: a write through a pointer past its element traps instead of writing element 0" {
	const ctx = evalOrcVM("let bytes: uint8[] = [11, 22, 33]; const view: Span<uint8> = bytes; const p = view as Ptr<uint8>; p[1] = 66; console.log(`${bytes[0]} ${bytes[1]}`);");
	assert ctx.error.includes("cannot index a pointer past the element it addresses on the Raiser VM"), ctx.error;
	assert ctx.output == "";
}

test "engine: a struct pointer keeps its object through Ptr<void> on the vm" {
	const ctx = evalOrcVM("struct S { n: int32; } let s: S = { n: 3 }; const raw = s as Ptr<void>; const p = raw as Ptr<S>; p[].n = 4; console.log(`${s.n}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "4\n";
}

// --- Conditions: a comparison in condition position is one compare-and-skip ---

function compiledFunc(code: string, name: string): RaiserFunction {
	const mod = compileForOrc(code);
	for (const f of mod.functions) {
		if (f.name == name) return f;
	}
	unreachable;
	return mod.functions[0];
}

function backJumpSpan(f: RaiserFunction): number {
	for (let i = 0; i < f.code.length; i = i + 1) {
		if (f.code[i].op == RaiserOpcode.Jump && getSignedAx(f.code[i]) < 0) return -getSignedAx(f.code[i]);
	}
	return 0;
}

test "engine: a for loop tests its bound with one compare-and-skip and keeps no old value of i++" {
	const sum = compiledFunc("function sum(n: int64): int64 { let s: int64 = 0; for (let i: int64 = 0; i < n; i++) { s += i; } return s; } console.log(`${sum(10)}`);", "sum");
	const text = disasmFunc(sum);
	assert backJumpSpan(sum) == 4, text;
	assert !text.includes("; true") && !text.includes("; false"), text;
	const fl = compiledFunc("function sum(n: float64): float64 { let s: float64 = 0.0; for (let i: float64 = 0.0; i < n; i++) { s += i; } return s; } console.log(`${sum(10.0)}`);", "sum");
	assert backJumpSpan(fl) == 6, disasmFunc(fl);
	const wh = compiledFunc("function f(n: int64): int64 { let i: int64 = 0; while (i < n) { i++; } return i; } console.log(`${f(3)}`);", "f");
	assert backJumpSpan(wh) == 3, disasmFunc(wh);
	const st = compiledFunc("function f(a: string, b: string): int64 { let i: int64 = 0; while (a < b && i < 3) { i++; } return i; } console.log(`${f('a', 'b')}`);", "f");
	assert !disasmFunc(st).includes("; true"), disasmFunc(st);
}

test "engine: an if on a comparison emits no bool constant and no compare against zero" {
	const f = compiledFunc("function f(a: int64, b: int64): int64 { if (a < b) { return 1; } return 2; } console.log(`${f(1, 2)}`);", "f");
	const text = disasmFunc(f);
	assert opName(f.code[0].op) == "BrGeI64" && countNamed(f, "Jump") == 0 && countNamed(f, "LoadConst") == 0, text;
}

function condForms(op: string, ty: string, a: string, b: string): string {
	const A = `(a ${op} b)`;
	const variants = [A, `!${A}`, `${A} && t`, `${A} || f`, `t && ${A}`, `f || ${A}`, `!(${A} && t)`, `!(${A} || f)`, `!${A} || f`, `!${A} && t`, `(${A} && t) || f`, `${A} && ${A}`, `${A} || ${A}`, `!!${A}`, `(${A} || f) && (t && ${A})`];
	let body = "";
	for (const c of variants) {
		body = body + ` if (${c}) { r = r + '1'; } else { r = r + '0'; }`
			+ ` r = r + ((${c}) ? '1' : '0');`
			+ ` w = '0'; while (${c}) { w = '1'; break; } r = r + w;`
			+ ` n = 0; do { n = n + 1; } while ((${c}) && n < 3); r = r + (n > 1 ? '1' : '0');`
			+ ` fc = '0'; for (let k = 0; (${c}) && k < 1; k++) { fc = '1'; } r = r + fc;`;
	}
	return `function chk(a: ${ty}, b: ${ty}, t: boolean, f: boolean): string { let r = ''; let w = '0'; let n = 0; let fc = '0';${body} return r; }`
		+ ` const as: ${ty}[] = [${a}]; const bs: ${ty}[] = [${b}];`
		+ ` for (let i = 0; i < as.length; i++) { console.log(chk(as[i], bs[i], true, false)); }`;
}

function expectedForms(truth: boolean): string {
	const negated = [false, true, false, false, false, false, true, true, true, true, false, false, false, false, false];
	let out = "";
	for (const neg of negated) {
		const bit = (truth != neg) ? "1" : "0";
		out = out + bit + bit + bit + bit + bit;
	}
	return out;
}

function condTruth(op: string, a: float64, b: float64): boolean {
	return match (op) {
		"==" => a == b,
		"!=" => a != b,
		"<" => a < b,
		"<=" => a <= b,
		">" => a > b,
		_ => a >= b,
	};
}

function condTruthStr(op: string, a: string, b: string): boolean {
	return match (op) {
		"==" => a == b,
		"!=" => a != b,
		"<" => a < b,
		"<=" => a <= b,
		">" => a > b,
		_ => a >= b,
	};
}

function numericCondsFailure(ty: string, aLits: string[], bLits: string[], aVals: float64[], bVals: float64[]): string {
	for (const op of ["==", "!=", "<", "<=", ">", ">="]) {
		const ctx = evalOrcVM(condForms(op, ty, aLits.join(", "), bLits.join(", ")));
		if (ctx.error != "") return `${ty} ${op}: ${ctx.error}`;
		let want = "";
		for (let i = 0; i < aVals.length; i++) want = want + expectedForms(condTruth(op, aVals[i], bVals[i])) + "\n";
		if (ctx.output != want) return `${ty} ${op}: ${ctx.output}`;
	}
	return "";
}

test "engine: every comparison drives if, ternary, while, do-while, for, &&, || and ! on int64" {
	const failure = numericCondsFailure("int64", ["1", "2", "2", "-1", "5"], ["2", "1", "2", "1", "-5"], [1, 2, 2, -1, 5], [2, 1, 2, 1, -5]);
	assert failure == "", failure;
}

test "engine: every comparison drives every condition form on float64, NaN included" {
	const nan = "(0.0 / 0.0)";
	const failure = numericCondsFailure("float64", ["1.5", "2.5", "2.5", nan, "1.0", nan, "-0.0"], ["2.5", "1.5", "2.5", "1.0", nan, nan, "0.0"],
		[1.5, 2.5, 2.5, 0.0 / 0.0, 1.0, 0.0 / 0.0, -0.0], [2.5, 1.5, 2.5, 1.0, 0.0 / 0.0, 0.0 / 0.0, 0.0]);
	assert failure == "", failure;
}

test "engine: every comparison drives every condition form on narrow unsigned ints" {
	const failure = numericCondsFailure("uint8", ["1", "200", "255", "0"], ["2", "100", "255", "255"], [1, 200, 255, 0], [2, 100, 255, 255]);
	assert failure == "", failure;
}

test "engine: unsigned 64-bit ordering in a condition is unsigned" {
	for (const op of ["<", "<=", ">", ">="]) {
		const ctx = evalOrcVM(condForms(op, "uint64", "1, 0xFFFFFFFFFFFFFFFF, 1", "0xFFFFFFFFFFFFFFFF, 1, 1"));
		assert ctx.error == "", ctx.error;
		const wantTruth = match (op) {
			"<" => [true, false, false],
			"<=" => [true, false, true],
			">" => [false, true, false],
			_ => [false, true, true],
		};
		let want = "";
		for (const w of wantTruth) want = want + expectedForms(w) + "\n";
		assert ctx.output == want, `uint64 ${op}: ${ctx.output}`;
	}
}

test "engine: every comparison drives every condition form on strings" {
	const aVals = ["a", "b", "a", "", "ab"];
	const bVals = ["b", "a", "a", "a", "a"];
	for (const op of ["==", "!=", "<", "<=", ">", ">="]) {
		const ctx = evalOrcVM(condForms(op, "string", aVals.map((x) => `'${x}'`).join(", "), bVals.map((x) => `'${x}'`).join(", ")));
		assert ctx.error == "", `string ${op}: ${ctx.error}`;
		let want = "";
		for (let i = 0; i < aVals.length; i++) want = want + expectedForms(condTruthStr(op, aVals[i], bVals[i])) + "\n";
		assert ctx.output == want, `string ${op}: ${ctx.output}`;
	}
}

test "engine: null comparisons, bool variables and calls drive conditions" {
	const ctx = evalOrcVM("function g(x: string | null, t: boolean): string { let r = '';"
		+ " if (x === null) { r = r + 'a'; } else { r = r + 'b'; }"
		+ " if (x !== null) { r = r + 'c'; } else { r = r + 'd'; }"
		+ " r = r + ((x === null) ? 'e' : 'f');"
		+ " if (x !== null && t) { r = r + 'g'; } else { r = r + 'h'; }"
		+ " if (!(x === null) || !t) { r = r + 'i'; } else { r = r + 'j'; }"
		+ " let n = 0; while (x === null && n < 1) { n = n + 1; } r = r + `${n}`; return r; }"
		+ " function yes(): boolean { return true; } function no(): boolean { return false; }"
		+ " let s: string | null = 's'; let z: string | null = null;"
		+ " console.log(g(z, true)); console.log(g(s, true)); console.log(g(s, false));"
		+ " let q = 0; if (yes() && !no()) { q = q + 1; } if (no() || yes()) { q = q + 1; } if (!yes()) { q = q + 10; } console.log(`${q}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "adehj1\nbcfgi0\nbcfhi0\n2\n", ctx.output;
}

test "engine: an if without an else leaves no jump to the next instruction" {
	const g = compiledFunc("function g(a: int64, b: int64): int64 { if (a < b) { return 1; } return 2; } console.log(`${g(1, 2)}`);", "g");
	for (const inst of g.code) {
		assert !(inst.op == RaiserOpcode.Jump && getSignedAx(inst) == 0), disasmFunc(g);
	}
}

test "engine: an update statement keeps no old value and an update used as a value still returns it" {
	const ctx = evalOrcVM("class C { n: int32 = 5; } const c = new C(); const xs: int32[] = [7]; let i = 0;"
		+ " i++; ++i; c.n++; xs[0]--; for (let k = 0; k < 2; k++) { i--; }"
		+ " const a = i++; const b = ++i; const d = c.n++; const e = xs[0]--;"
		+ " console.log(`${i} ${a} ${b} ${c.n} ${d} ${xs[0]} ${e}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "2 0 2 7 6 5 6\n", ctx.output;
	const loop = compiledFunc("function f(n: int64): int64 { let i: int64 = 0; i++; return i; } console.log(`${f(1)}`);", "f");
	for (const inst of loop.code) {
		assert inst.op != RaiserOpcode.Move, disasmFunc(loop);
	}
}

// --- Destinations: a value bound for a known register is computed into it ---

function countOp(f: RaiserFunction, op: RaiserOpcode): number {
	let n = 0;
	for (const inst of f.code) {
		if (inst.op == op) n = n + 1;
	}
	return n;
}

test "engine: a call argument, a local assignment and a branch value land without a Move" {
	const fib = compiledFunc("function fib(n: int32): int32 { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } console.log(`${fib(10)}`);", "fib");
	assert countOp(fib, RaiserOpcode.Move) == 0, disasmFunc(fib);
	const asg = compiledFunc("function f(a: int64, b: int64): int64 { let x: int64 = 1; x = a + b; x = x + a; return x; } console.log(`${f(1, 2)}`);", "f");
	assert countOp(asg, RaiserOpcode.Move) == 0, disasmFunc(asg);
	const tern = compiledFunc("function f(a: int64, b: int64): int64 { let x: int64 = 0; x = a < b ? a + 1 : b + 2; return x; } console.log(`${f(1, 2)}`);", "f");
	assert countOp(tern, RaiserOpcode.Move) == 1, disasmFunc(tern);
	const glob = compiledFunc("let g: int64 = 5; function h(a: int64, b: int64): int64 { return a + b; } function f(a: int64): int64 { return h(g, a * 2); } console.log(`${f(1)}`);", "f");
	assert countOp(glob, RaiserOpcode.Move) == 0, disasmFunc(glob);
}

test "engine: a condition on a float, a string or a negated value jumps on its ToBoolean" {
	const ctx = evalOrcVM("function t(x: float64, s: string): string {"
		+ " let r = ''; if (x) r = r + 'x'; if (s) r = r + 's'; if (!x) r = r + 'X'; if (!s) r = r + 'S';"
		+ " if (x || s) r = r + 'o'; if (x && s) r = r + 'a'; let n = 0; while (x) { n = n + 1; x = 0.0; }"
		+ " do { n = n + 10; } while (s && n < 5); return `${r} ${n}`; }"
		+ " const zero = 0.0; console.log(t(zero / zero, '')); console.log(t(0.5, 'a'));");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "XS 10\nxsoa 11\n", ctx.output;
}

test "engine: a destination the expression reads, or a merge of branches, keeps its value" {
	const ctx = evalOrcVM("function h(a: int64, b: int64, c: int64): int64 { return a * 100 + b * 10 + c; }"
		+ " function k(a: int64, b: int64): int64 { return a - b; }"
		+ " function t(a: int64, b: int64, p: boolean, q: boolean): string {"
		+ " let x: int64 = a; x = b + x; let y: int64 = a; y = k(y, b); let z: int64 = a; z = p ? z + 1 : z + 2;"
		+ " let u: int64 = b; u = (p && q) ? u : u * 2; let w: boolean = p; w = q || p; let v: int64 = a; v = k(v, v) + v;"
		+ " return `${x} ${y} ${z} ${u} ${w} ${v} ${h(a, a + b, p ? b : a)} ${h(b, k(a, b), a - b)}`; }"
		+ " let g1: int64 = 3; let g2: float64 = 2.5; let ff: float64 = 1.5; ff = g2 * ff;"
		+ " console.log(t(1, 2, true, false)); console.log(t(4, 3, false, true)); console.log(`${h(g1, g1 + 1, g1 * 2)} ${ff}`);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "3 -1 2 4 true 1 132 189\n7 1 6 6 true 4 474 311\n346 3.75\n", ctx.output;
}

test "engine: a body ending in return has no second return, one a jump can reach keeps it" {
	const plain = compiledFunc("function f(a: int64): int64 { return a + 1; } console.log(`${f(1)}`);", "f");
	assert plain.code[plain.code.length - 1].op == RaiserOpcode.Ret && countOp(plain, RaiserOpcode.Ret) == 1, disasmFunc(plain);
	const early = compiledFunc("function f(a: int64): int64 { if (a < 0) { return 0; } return a; } console.log(`${f(1)}`);", "f");
	assert countOp(early, RaiserOpcode.Ret) == 2, disasmFunc(early);
	const ctx = evalOrcVM("function loopy(a: int64): int64 { while (a < 10) { if (a == 7) { return a; } a = a + 1; } return -1; }"
		+ " function onElse(a: int64): int64 { if (a > 0) { return 1; } else { return 2; } }"
		+ " function noRet(a: int64): void { if (a > 0) { console.log('pos'); } }"
		+ " function tried(a: int64): int64 { try { return a; } catch (e) { return -2; } }"
		+ " console.log(`${loopy(1)} ${loopy(8)} ${onElse(1)} ${onElse(-1)} ${tried(5)}`); noRet(1); noRet(-1);");
	assert ctx.error == "", ctx.error;
	assert ctx.output == "7 -1 1 2 5\npos\n", ctx.output;
}

// --- A load whose destination holds the last reference to its source ---

test "engine: a field load into the register holding the only reference to its object reads the field first" {
	const link = "class Link { v: int32; next: Link | null = null; constructor(v: int32) { this.v = v; } } function chain(): Link { const a = new Link(1); const b = new Link(2); b.next = new Link(3); a.next = b; return a; }";
	const moved = evalOrcVM(`${link} function walk(): int32 { let cur: Link | null = chain(); let seen: int32 = 0; while (cur != null) { seen = seen * 10 + cur.v; cur = move cur.next; } return seen; } console.log(\`\${walk()}\`);`);
	assert moved.error == "" && moved.output == "123\n", `${moved.error} ${moved.output}`;
	const plain = evalOrcVM(`${link} function walk(): int32 { let cur: Link | null = chain(); let seen: int32 = 0; while (cur != null) { seen = seen * 10 + cur.v; cur = cur.next; } return seen; } console.log(\`\${walk()}\`);`);
	assert plain.error == "" && plain.output == "123\n", `${plain.error} ${plain.output}`;
}

test "engine: an element load into the register holding the only reference to its array reads the element first" {
	const ctx = evalOrcVM("function inner(): int64 { let a: int64[][] = [[7, 8]]; let b: int64[] = a[0]; return b[1]; } function nest(): number { let g: number[][][] = [[[5]]]; let h: number[][] = g[0]; let k: number[] = h[0]; return k[0]; } console.log(`${inner()} ${nest()}`);");
	assert ctx.error == "" && ctx.output == "8 5\n", `${ctx.error} ${ctx.output}`;
}

// --- Immediate operands: an integer literal that fits the 16-bit field rides in the instruction ---

function countNamed(f: RaiserFunction, name: string): number {
	let n = 0;
	for (const inst of f.code) {
		if (opName(inst.op) == name) n = n + 1;
	}
	return n;
}

test "engine: fib, a counting loop and a while on zero use the immediate forms" {
	const fib = compiledFunc("function fib(n: int64): int64 { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } console.log(`${fib(10)}`);", "fib");
	assert countNamed(fib, "LoadConst") == 0 && countNamed(fib, "BrGeI64Imm") == 1 && countNamed(fib, "SubI64Imm") == 2, disasmFunc(fib);
	assert fib.code.length == 8, disasmFunc(fib);
	const run = compiledFunc("function run(): int64 { let s: int64 = 0; for (let i: int64 = 0; i < 5000000; i = i + 1) { s = s + i; } return s; } console.log(`${run()}`);", "run");
	assert countNamed(run, "LoadInt") == 2 && countNamed(run, "AddI64Imm") == 1, disasmFunc(run);
	assert countNamed(run, "LoadConst") == 1 && countNamed(run, "BrGeI64") == 1, disasmFunc(run);
	const wh = compiledFunc("function w(x: int64): int64 { let n: int64 = 0; while (x != 0) { x = x - 1; n++; } return n; } console.log(`${w(3)}`);", "w");
	assert countNamed(wh, "LoadConst") == 0 && countNamed(wh, "BrEqI64Imm") == 1 && countNamed(wh, "SubI64Imm") == 1 && countNamed(wh, "AddI64Imm") == 1, disasmFunc(wh);
	assert backJumpSpan(wh) == 4, disasmFunc(wh);
	const ctx = evalOrcVM("function fib(n: int64): int64 { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }"
		+ " function w(x: int64): int64 { let n: int64 = 0; while (x != 0) { x = x - 1; n++; } return n; } console.log(`${fib(15)} ${w(7)}`);");
	assert ctx.error == "" && ctx.output == "610 7\n", `${ctx.error} ${ctx.output}`;
}

test "engine: an immediate at the field bound is kept and one past it falls back to the register form" {
	const f = compiledFunc("function f(y: int64): int64 { return (y + 32767) + (y + 32768) + (y - -32768) + (y - -32769); } console.log(`${f(1)}`);", "f");
	assert countNamed(f, "AddI64Imm") == 1 && countNamed(f, "SubI64Imm") == 1 && countNamed(f, "AddI64") == 4 && countNamed(f, "SubI64") == 1, disasmFunc(f);
	const c = compiledFunc("function c(x: int64): int64 { let r: int64 = 0; if (x == 32767) r += 1; if (x == 32768) r += 2; if (x > -32768) r += 4; if (x > -32769) r += 8; return r; } console.log(`${c(1)}`);", "c");
	assert countNamed(c, "BrNeI64Imm") == 1 && countNamed(c, "BrNeI64") == 1 && countNamed(c, "BrLeI64Imm") == 1 && countNamed(c, "BrLeI64") == 1, disasmFunc(c);
	const ctx = evalOrcVM("function f(y: int64): int64 { return (y + 32767) + (y + 32768) + (y - -32768) + (y - -32769); }"
		+ " function c(x: int64): int64 { let r: int64 = 0; if (x == 32767) r += 1; if (x == 32768) r += 2; if (x > -32768) r += 4; if (x > -32769) r += 8; return r; }"
		+ " console.log(`${f(1)} ${c(32767)} ${c(32768)} ${c(-32768)} ${c(-32769)} ${c(-32770)}`);");
	assert ctx.error == "" && ctx.output == "131076 13 14 8 0 0\n", `${ctx.error} ${ctx.output}`;
}

test "engine: an immediate add or sub stops on overflow at int64 and at the narrow width, and takes a negative operand" {
	const programs = [
		"function f(x: int64): int64 { return x + 1; } console.log(`${f(9223372036854775807)}`);",
		"function f(x: int64): int64 { return x - 1; } console.log(`${f(-9223372036854775807 - 1)}`);",
		"function f(x: int64): int64 { return x - -1; } console.log(`${f(9223372036854775807)}`);",
		"function f(x: int32): int32 { return x + 1; } console.log(`${f(2147483647)}`);",
		"function f(x: int8): int8 { return x - 1; } console.log(`${f(-128)}`);",
	];
	for (const program of programs) {
		const ctx = evalOrcVM(program);
		assert ctx.error.indexOf("over- or underflow") >= 0, program;
		assert ctx.output == "", program;
	}
	const f = compiledFunc("function f(x: int32): int32 { return x + 1; } console.log(`${f(1)}`);", "f");
	assert countNamed(f, "AddI64Imm") == 1 && countNamed(f, "NarrowS") == 1, disasmFunc(f);
	const ctx = evalOrcVM("function a(x: int64): int64 { return x + -5; } function b(x: int64): int64 { return x - -5; } function c(x: int32): int32 { return x + 1; }"
		+ " console.log(`${a(10)} ${b(10)} ${c(2147483646)} ${a(9223372036854775807)} ${b(-9223372036854775807 - 1)}`);");
	assert ctx.error == "" && ctx.output == "5 15 2147483647 9223372036854775802 -9223372036854775803\n", `${ctx.error} ${ctx.output}`;
}

test "engine: an unsigned operand keeps its wrapping add and its unsigned compare beside an immediate" {
	const f = compiledFunc("function f(x: uint64, y: uint32): boolean { const z = y + 1; return x < 5 || z == 0; } console.log(`${f(1, 2)}`);", "f");
	assert countNamed(f, "BltU64") == 1 && countNamed(f, "BltI64Imm") == 0 && countNamed(f, "AddU64") == 1 && countNamed(f, "AddI64Imm") == 0, disasmFunc(f);
	assert countNamed(f, "BeqI64Imm") == 1, disasmFunc(f);
	const ctx = evalOrcVM("function lt(x: uint64): boolean { return x < 5; } function wrap(y: uint32): uint32 { return y + 1; } function zero(x: uint64): boolean { return x == 0; }"
		+ " console.log(`${lt(18446744073709551615)} ${lt(4)} ${wrap(4294967295)} ${zero(0)} ${zero(18446744073709551615)}`);");
	assert ctx.error == "" && ctx.output == "false true 0 true false\n", `${ctx.error} ${ctx.output}`;
}

// --- Compare-and-branch: an integer condition is one instruction carrying its jump target ---

test "engine: an integer condition branches in one instruction and a float one keeps its skip and jump" {
	const fib = compiledFunc("function fib(n: int64): int64 { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } console.log(`${fib(10)}`);", "fib");
	assert countNamed(fib, "Jump") == 0 && countNamed(fib, "BrGeI64Imm") == 1 && countNamed(fib, "BltI64Imm") == 0, disasmFunc(fib);
	assert fib.code.length == 8, disasmFunc(fib);
	const g = compiledFunc("function g(a: int64, b: int64): int64 { if (a < b) { return 1; } return 2; } console.log(`${g(1, 2)}`);", "g");
	assert opName(g.code[0].op) == "BrGeI64" && countNamed(g, "Jump") == 0, disasmFunc(g);
	const dw = compiledFunc("function f(): int64 { let n: int64 = 0; do { n++; } while (n < 10); return n; } console.log(`${f()}`);", "f");
	assert countNamed(dw, "BrLtI64Imm") == 1 && countNamed(dw, "Jump") == 0, disasmFunc(dw);
	const mix = compiledFunc("function f(a: int64, b: int64, c: int64): int64 { if (a < b || c == 3) { return 1; } return 2; } console.log(`${f(1, 2, 3)}`);", "f");
	assert countNamed(mix, "Jump") == 0, disasmFunc(mix);
	const val = compiledFunc("function f(a: int64, b: int64): boolean { return a < b; } console.log(`${f(1, 2)}`);", "f");
	assert countNamed(val, "BltI64") == 1 && countNamed(val, "BrGeI64") == 0, disasmFunc(val);
	const fl = compiledFunc("function f(a: float64, b: float64): int64 { if (a < b) { return 1; } return 2; } console.log(`${f(1.0, 2.0)}`);", "f");
	assert countNamed(fl, "BltF64") == 1 && countNamed(fl, "Jump") == 1, disasmFunc(fl);
}

test "engine: a branch over more than 32768 instructions keeps its target and a do-while branches back" {
	const source = "function f(x: int64): int64 { let s: int64 = 0; if (x < 5) { const a: int64[] = [" + "0,".repeat(20000) + "0]; s = s + a.length; } return s; }"
		+ " function g(): int64 { let n: int64 = 0; do { n++; } while (n < 20); return n; } console.log(`${f(1)} ${f(9)} ${g()}`);";
	const f = compiledFunc(source, "f");
	let span: int64 = 0;
	for (const inst of f.code) {
		if (opName(inst.op) == "BrGeI64Imm") span = branchOffset(inst.c);
	}
	assert span > 32768, `${span}`;
	const ctx = evalOrcVM(source);
	assert ctx.error == "" && ctx.output == "20001 0 20\n", `${ctx.error} ${ctx.output}`;
}

// --- Strings on the string heap ---

test "orc: strings built and dropped in a loop leave the string heap bounded" {
	const vm = evalOrcVM("let n = 0; for (let i = 0; i < 300; i++) { const s = `item ${i}` + \"-\" + `${i}`; n = n + s.length; } console.log(`${n}`);");
	assert vm.error == "", vm.error;
	assert vm.output == "3380\n";
	assert vm.arrayHeap.strings.texts.length < 30;
	assert heapStringLive(vm.arrayHeap) < 30;
}

test "orc: strings dropped with their array and overwritten in an object field are released" {
	const vm = evalOrcVM("let a: string[] = []; const o = { s: \"\" }; for (let i = 0; i < 200; i++) { a.push(`v${i}`); o.s = `f${i}`; } a = []; console.log(o.s);");
	assert vm.error == "", vm.error;
	assert vm.output == "f199\n";
	assert heapStringLive(vm.arrayHeap) < 20;
}

test "orc: a string written into the register of its only source keeps its value" {
	const vm = evalOrcVM("let s = \"\"; for (let i = 0; i < 50; i++) { s = s + \"x\"; } console.log(`${s.length}`);"
		+ " let t = \"abcdefgh\"; while (t.length > 3) { t = t.slice(1); } console.log(t);"
		+ " const o = { s: \"a\" }; for (let i = 0; i < 3; i++) { o.s = o.s + \"b\"; } console.log(o.s);"
		+ " const arr = [\"wxyz\", \"k\"]; arr[0] = arr[0].slice(2); arr[1] = arr[1] + arr[1]; console.log(arr[0] + \",\" + arr[1]);"
		+ " let c = \"q\"; c = c.charAt(0) + c; console.log(c);");
	assert vm.error == "", vm.error;
	assert vm.output == "50\nfgh\nabbb\nyz,kk\nqq\n";
}

test "orc: non-ASCII strings keep their bytes through the string tier" {
	const vm = evalOrcVM("console.log(\"é\".padStart(4, \"x\")); console.log(\"日本\".padEnd(5, \"·\"));"
		+ " const m = \"naïve\".padStart(7, \"é\"); console.log(m + \"|\" + `${m.length}`);"
		+ " for (const p of [\"a\", \"é\", \"日\"]) { console.log(p.padStart(3, \"-\")); }");
	assert vm.error == "", vm.error;
	assert vm.output == "xxxé\n日本···\néénaïve|7\n--a\n--é\n--日\n";
}

test "orc: a string a spawned strand extends leaves the sender's copy unchanged" {
	const vm = evalOrcVM("const box = { text: \"abc\", tags: [\"é\", \"x\"] };"
		+ " const f = spawn(() => { let t = box.text; t = t + \"Z\"; let u = box.tags[0]; u = u + \"日\"; return t + u + box.tags[1]; });"
		+ " const r = await f; console.log(box.text + \"|\" + box.tags[0] + \"|\" + r);"
		+ " const word = \"né\"; const g = spawn(() => { let w = word; for (let i = 0; i < 3; i++) { w = w + word; } return w; });"
		+ " console.log((await g) + \"|\" + word);");
	assert vm.error == "", vm.error;
	assert vm.output == "abc|é|abcZé日x\nnénénéné|né\n";
}

test "orc: string equality, ordering and switch are by text, not by handle" {
	const vm = evalOrcVM("const a = \"ab\" + \"c\"; const b = \"abc\";"
		+ " console.log(`${a == b} ${a != b} ${a < \"abd\"} ${a <= b} ${a > \"abb\"} ${a >= \"abd\"}`);"
		+ " function kind(x: string): number { switch (x) { case \"abc\": return 1; case \"é\": return 2; default: return 3; } }"
		+ " console.log(`${kind(a)} ${kind(\"é\")} ${kind(\"zz\")} ${kind(\"a\" + \"bc\")}`);"
		+ " const k = [\"x\", \"y\"]; console.log(`${k[0] == \"x\"} ${k[1] == \"x\"}`);"
		+ " const e = { n: \"x\" + \"y\" }; console.log(`${e.n == \"xy\"} ${e.n < \"xz\"}`);");
	assert vm.error == "", vm.error;
	assert vm.output == "true false true true true false\n1 2 3 1\ntrue false\ntrue true\n";
}

// --- Run-time strings never enter the process-wide constant table ---

test "arena: strings built and dropped in a loop leave the string heap bounded" {
	const vm = evalArenaVM("let s = \"\"; let n = 0; for (let i = 0; i < 100000; i++) { s = `k${i}` + \"x\"; n = n + s.length; } console.log(`${n}`);");
	assert vm.error == "", vm.error;
	assert vm.output == "688890\n", vm.output;
	assert heapStringLive(vm.arrayHeap) < 30, `${heapStringLive(vm.arrayHeap)}`;
	assert vm.arrayHeap.strings.texts.length < 30, `${vm.arrayHeap.strings.texts.length}`;
}

const heldByContainer = "const o = { s: `f${1}` }; const a = [`g${2}`];"
	+ " let t = o.s; t = \"x\" + \"y\"; let u = a[0]; u = \"z\" + \"w\";"
	+ " console.log(o.s + a[0] + t + u);";

test "orc: a string a container holds survives the register that read it being overwritten" {
	const vm = evalOrcVM(heldByContainer);
	assert vm.error == "", vm.error;
	assert vm.output == "f1g2xyzw\n", vm.output;
}

test "arena: a string a container holds survives the register that read it being overwritten" {
	const vm = evalArenaVM(heldByContainer);
	assert vm.error == "", vm.error;
	assert vm.output == "f1g2xyzw\n", vm.output;
}

test "a string a host function stores in the array it builds is held by that array in either gc mode" {
	ensureHostTableLoaded();
	const mod = makeTestModule(
		[raiserABC(RaiserOpcode.CallHost, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[raiserConstString("msProcessArgv")]
	);
	for (const mode of ["orc", "arena"]) {
		const vm = createVM(mod, mode);
		vm.programArgv = ["a.ms", "b c"];
		execLoop(vm);
		assert vm.error == "", vm.error;
		const argvArray = vm.exitValue.intVal;
		assert heapArrayLen(vm.arrayHeap, argvArray) == 2;
		for (let i = 0; i < 2; i++) {
			const item = heapArrayGet(vm.arrayHeap, argvArray, i);
			assert vm.arrayHeap.strings.rc[item.intVal] == 1, `${mode} ${i}`;
		}
	}
}

// --- A self-append extends the register's own string in place ---

const selfAppend = "function grow(): number { let s = \"\"; for (let i = 0; i < 20000; i++) { s = s + \"ab\"; } return s.length; }"
	+ " console.log(grow() == 40000 ? \"ok\" : \"bad\");";

test "orc: appending to a string held once keeps one heap item" {
	const vm = evalOrcVM(selfAppend);
	assert vm.error == "", vm.error;
	assert vm.output == "ok\n", vm.output;
	assert vm.arrayHeap.strings.texts.length == 1, `${vm.arrayHeap.strings.texts.length}`;
}

test "arena: appending to a string held once keeps one heap item" {
	const vm = evalArenaVM(selfAppend);
	assert vm.error == "", vm.error;
	assert vm.output == "ok\n", vm.output;
	assert vm.arrayHeap.strings.texts.length == 1, `${vm.arrayHeap.strings.texts.length}`;
}

const sharedAppend = "function f(): string { let s = \"a\" + `${1}`; const t = s; s = s + \"x\"; s = s + s; const o = { v: s }; s = s + \"y\"; return t + \"|\" + s + \"|\" + o.v; }"
	+ " console.log(f());";

test "orc: appending to a string another holder shares leaves the holder unchanged" {
	const vm = evalOrcVM(sharedAppend);
	assert vm.error == "", vm.error;
	assert vm.output == "a1|a1xa1xy|a1xa1x\n", vm.output;
}

test "arena: appending to a string another holder shares leaves the holder unchanged" {
	const vm = evalArenaVM(sharedAppend);
	assert vm.error == "", vm.error;
	assert vm.output == "a1|a1xa1xy|a1xa1x\n", vm.output;
}

test "orc: a bare return in a constructor still yields the object" {
	const vm = evalOrcVM("class Early { f: string = 'none'; constructor(v: string, skip: boolean) { if (skip) return; this.f = v; } }"
		+ " class Base { tag: string = 'b'; constructor(t: string) { if (t == '') return; this.tag = t; } }"
		+ " class Kid extends Base { k: number = 0; constructor(t: string, skip: boolean) { super(t); if (skip) return; this.k = 2; } }"
		+ " class Guarded { n: number = 0; constructor(skip: boolean) { try { if (skip) return; this.n = 1; } finally { this.n = this.n + 10; } } }"
		+ " const a = new Early('x', true); const b = new Early('y', false); const c = new Kid('', true); const d = new Kid('t', false);"
		+ " const g = new Guarded(true); const h = new Guarded(false);"
		+ " console.log(`${a.f} ${b.f} ${c.tag}${c.k} ${d.tag}${d.k} ${g.n} ${h.n}`);");
	assert vm.error == "", vm.error;
	assert vm.output == "none y b0 t2 10 11\n", vm.output;
}


const finallyInFlight = "let log = ''; function note(s: string): void { log = log + s + '|'; } function boom(m: number): void { throw m; }"
	+ " function ownCatch(): void { try { boom(9); } catch (e) { note('own'); } }"
	+ " function replaced(): void { try { try { boom(1); } finally { note('f'); boom(2); } } catch (e) { note(String(e as number)); } }"
	+ " function viaCall(): void { try { try { boom(3); } finally { ownCatch(); } } catch (e) { note(String(e as number)); } }"
	+ " function sameFrame(): void { try { try { boom(3); } finally { try { boom(9); } catch (e) { note('own'); } } } catch (e) { note(String(e as number)); } }"
	+ " function returns(): number { try { return 7; } finally { ownCatch(); try { boom(8); } catch (e) { note('own2'); } } }"
	+ " function normal(): void { try { note('body'); } finally { ownCatch(); note('fin'); } }"
	+ " function twoLevels(): void { try { try { try { boom(4); } finally { ownCatch(); note('f1'); } } finally { ownCatch(); note('f2'); } } catch (e) { note(String(e as number)); } }"
	+ " function cancelled(): number { try { try { boom(5); } finally { return 3; } } catch (e) { return 4; } }"
	+ " replaced(); viaCall(); sameFrame(); note(`${returns()}`); normal(); twoLevels(); note(`${cancelled()}`); console.log(log);";
const finallyInFlightOut = "f|2|own|3|own|3|own|own2|7|body|own|fin|own|f1|own|f2|4|3|\n";

test "orc: a throw in a finally replaces the raise, and a catch inside it keeps the raise in flight" {
	const vm = evalOrcVM(finallyInFlight);
	assert vm.error == "", vm.error;
	assert vm.output == finallyInFlightOut, vm.output;
}

test "arena: a throw in a finally replaces the raise, and a catch inside it keeps the raise in flight" {
	const vm = evalArenaVM(finallyInFlight);
	assert vm.error == "", vm.error;
	assert vm.output == finallyInFlightOut, vm.output;
}
