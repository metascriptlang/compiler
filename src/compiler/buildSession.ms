import { Node, Type, TypeFlag, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { CModuleOutput } from "../codegen/c/index";
import { forEachChild } from "../ast/visitor";
import { CheckSession, createCheckSession } from "../checker/orchestrator";
import { resetInstantiationState, instanceArgsOf } from "../checker/instantiate";
import { resetDispatchRegistry } from "../checker/context";
import { resetRaises } from "../checker/raises";
import { resetResizeSummaries } from "../checker/varPartitions";
import { resetCapturedAssignments } from "../checker/flow";
import { resetDuVariantRegistry } from "../checker/types";
import { resetDuHashes } from "../analyzer/classify";
import { resetLinkState } from "../utils/linkState";
import { resetLiftedOps } from "../transform/lowering/destructorLifting";
import { ModuleError } from "../module/graph";
import { monoTypeKey } from "../monomorphize/registry";
import { HcrIndirectModule } from "../transform/native/hcrIndirect";
import { taHashString, transAmHashNode } from "./transam/hash";
import { KeyedOp } from "../codegen/c/types";
import { ContractClaim } from "../analyzer/writeEffects";
import { sameType } from "../checker/compat";

export enum BuildStatus {
	Built,
	UpToDate,
	Stale,
}

export interface LowerClaims {
	ops: KeyedOp[];
	contracts: ContractClaim[];
}

export function sameClaims(a: LowerClaims, b: LowerClaims): boolean {
	if (a.ops.length != b.ops.length || a.contracts.length != b.contracts.length) return false;
	for (let i = 0; i < a.ops.length; i += 1) {
		if (a.ops[i].key != b.ops[i].key || a.ops[i].sym.name != b.ops[i].sym.name) return false;
	}
	for (let i = 0; i < a.contracts.length; i += 1) {
		if (!sameContract(a.contracts[i], b.contracts[i])) return false;
	}
	return true;
}

function sameRoutine(a: Symbol | null, b: Symbol | null): boolean {
	if (a == null || b == null) return a == null && b == null;
	return a.modulePath == b.modulePath && a.name == b.name && a.disamb == b.disamb;
}

function sameContract(a: ContractClaim, b: ContractClaim): boolean {
	if (!sameRoutine(a.fn, b.fn) || !sameRoutine(a.clone, b.clone) || a.params.length != b.params.length || a.slots.length != b.slots.length) return false;
	for (let i = 0; i < a.params.length; i += 1) {
		if (a.params[i] != b.params[i]) return false;
	}
	for (let i = 0; i < a.slots.length; i += 1) {
		const x = a.holders[i];
		const y = b.holders[i];
		if (a.slots[i] != b.slots[i] || (x == null) != (y == null) || (x != null && x !== y && !sameType(x!, y!))) return false;
	}
	return true;
}

export interface PrepareMemo {
	program: Node;
	alive: string;
	before: string;
	writes: string[];
}

export interface DirectiveHit {
	source: string;
	dependencyFile: string;
	oFile: string;
}

export interface EmitMemo {
	program: Node;
	key: string;
	output: CModuleOutput;
	compileCmd: string;
	baseFp: string;
}

export class BuildSession {
	keep: boolean;
	check: CheckSession;
	lowerFingerprints: HashMap<string, string>;
	lowerDiagnostics: HashMap<string, ModuleError[]>;
	lowerClaims: HashMap<string, LowerClaims>;
	hcrTypeLayouts: HashMap<string, string>;
	hcrCoreModules: string[];
	staleReason: string;
	moduleCount: int32;
	lastBuilt: boolean;
	loweredCount: int32;
	instanceFingerprints: HashMap<Node, string>;
	typeShapes: HashMap<Type, string>;
	layoutDigests: HashMap<Type, string>;
	prepareMemos: HashMap<string, PrepareMemo>;
	emitMemos: HashMap<string, EmitMemo>;
	directiveMemos: HashMap<string, DirectiveHit[]>;
}

export function createBuildSession(keep: boolean): BuildSession {
	return {
		keep,
		check: createCheckSession(),
		lowerFingerprints: new HashMap<string, string>(),
		lowerDiagnostics: new HashMap<string, ModuleError[]>(),
		lowerClaims: new HashMap<string, LowerClaims>(),
		hcrTypeLayouts: new HashMap<string, string>(),
		hcrCoreModules: [],
		staleReason: "",
		moduleCount: 0,
		lastBuilt: false,
		loweredCount: 0,
		instanceFingerprints: new HashMap<Node, string>(),
		typeShapes: new HashMap<Type, string>(),
		layoutDigests: new HashMap<Type, string>(),
		prepareMemos: new HashMap<string, PrepareMemo>(),
		emitMemos: new HashMap<string, EmitMemo>(),
		directiveMemos: new HashMap<string, DirectiveHit[]>(),
	};
}

export function resetBuildState(): void {
	resetInstantiationState();
	resetDispatchRegistry();
	resetRaises();
	resetResizeSummaries();
	resetCapturedAssignments();
	resetDuVariantRegistry();
	resetDuHashes();
	resetLinkState();
	resetLiftedOps();
}

export function startSessionBuild(session: BuildSession): void {
	if (session.check.db == null) resetBuildState();
	session.staleReason = "";
	session.moduleCount = 0;
	session.loweredCount = 0;
	session.typeShapes = new HashMap<Type, string>();
	session.layoutDigests = new HashMap<Type, string>();
}

function mix(h: number, value: number): number {
	return (h * 31 + value) % 2147483647;
}

function typeShape(session: BuildSession, t: Type | null): string {
	if (t == null) return "_";
	const memo = session.typeShapes.get(t);
	if (memo != null) return memo;
	const shape = monoTypeKey(t) + "!" + String(t.typeFlags.excl(TypeFlag.HasAsgn).excl(TypeFlag.HasGenericParam) as uint64);
	session.typeShapes.set(t, shape);
	return shape;
}

function peelToDeclaration(t: Type): Type {
	let body = t;
	for (let hops = 0; hops < 8 && (body.kind == TypeKind.Alias || body.kind == TypeKind.Ref) && body.typeReturn != null; hops += 1) body = body.typeReturn;
	return body;
}

function layoutDigest(session: BuildSession, t: Type | null): string {
	if (t == null) return "_";
	const memo = session.layoutDigests.get(t);
	if (memo != null) return memo;
	const body = peelToDeclaration(t);
	let digest = typeShape(session, body);
	if (body.kind == TypeKind.Struct) {
		digest = digest + "{";
		for (let i = 0; i < body.typeNames.length; i += 1) {
			digest = digest + body.typeNames[i] + ":" + (i < body.typeChildren.length ? monoTypeKey(body.typeChildren[i]) : "void") + ",";
		}
		digest = digest + "}";
	} else if (body.kind == TypeKind.Enum) {
		digest = digest + "{";
		for (let i = 0; i < body.typeNames.length; i += 1) {
			digest = digest + body.typeNames[i] + (i < body.typeChildren.length ? "=" + String(body.typeChildren[i].typeValue) : "") + ",";
		}
		digest = digest + "}";
	}
	session.layoutDigests.set(t, digest);
	return digest;
}

function isWrapperKind(kind: TypeKind): boolean {
	return kind == TypeKind.Alias || kind == TypeKind.Ref || kind == TypeKind.Ptr || kind == TypeKind.Borrow || kind == TypeKind.Var
		|| kind == TypeKind.Array || kind == TypeKind.Span || kind == TypeKind.Set || kind == TypeKind.Sink || kind == TypeKind.Lent;
}

// An argument's own class and every by-value member reachable from it; a class-typed field is identity only.
function collectLayouts(session: BuildSession, t: Type | null, direct: boolean, visited: HashSet<Type>, out: string[]): void {
	if (t == null) return;
	const kind = t.kind;
	if (isWrapperKind(kind)) {
		if (direct && !visited.has(t)) {
			visited.add(t);
			collectLayouts(session, t.typeReturn, true, visited, out);
		}
		return;
	}
	if (kind == TypeKind.GenericInstance) {
		if (direct && !visited.has(t)) {
			visited.add(t);
			for (const arg of t.typeChildren) collectLayouts(session, arg, true, visited, out);
		}
		return;
	}
	if (kind == TypeKind.Enum) {
		if (!visited.has(t)) {
			visited.add(t);
			out.push(layoutDigest(session, t));
		}
		return;
	}
	if (kind == TypeKind.Struct) {
		if ((direct || t.typeFlags.has(TypeFlag.IsStruct)) && !visited.has(t)) {
			visited.add(t);
			out.push(layoutDigest(session, t));
			for (const field of t.typeChildren) collectLayouts(session, field, false, visited, out);
		}
		return;
	}
	if (kind == TypeKind.Union || kind == TypeKind.Tuple || kind == TypeKind.Distinct) {
		if (!visited.has(t)) {
			visited.add(t);
			for (const member of t.typeChildren) collectLayouts(session, member, direct, visited, out);
			collectLayouts(session, t.typeReturn, direct, visited, out);
		}
		return;
	}
	if (kind == TypeKind.SizedArray) {
		if (!visited.has(t)) {
			visited.add(t);
			collectLayouts(session, t.typeReturn, direct, visited, out);
		}
	}
}

function argFingerprint(session: BuildSession, arg: Type): string {
	const layouts: string[] = [];
	collectLayouts(session, arg, true, new HashSet<Type>(), layouts);
	return typeShape(session, arg) + "<" + layouts.join(";") + ">";
}

function foldTypes(session: BuildSession, node: Node, h: number): number {
	let acc = h;
	if (node.nodeType != null) acc = mix(acc, taHashString(typeShape(session, node.nodeType)) as number);
	const sym = node.resolvedSym;
	if (sym != null) acc = mix(acc, taHashString(sym.name + "|" + sym.modulePath + "|" + String(sym.disamb) + "|" + typeShape(session, sym.symbolType)) as number);
	const children: Node[] = [];
	forEachChild(node, (child: Node): void => { children.push(child); });
	for (const child of children) acc = foldTypes(session, child, acc);
	return acc;
}

function instanceFingerprint(session: BuildSession, node: Node): string {
	const memo = session.instanceFingerprints.get(node);
	if (memo != null) return memo;
	let identity = "";
	const sym = node.resolvedSym;
	if (sym != null && sym.instantiatedFrom != null) {
		const generic = sym.instantiatedFrom;
		identity = generic.modulePath + ":" + String(generic.item) + ":" + String(generic.disamb);
		for (const arg of instanceArgsOf(sym)) identity = identity + "|" + argFingerprint(session, arg);
	}
	const fingerprint = identity + "#" + String(foldTypes(session, node, transAmHashNode(node)));
	session.instanceFingerprints.set(node, fingerprint);
	return fingerprint;
}

export function instancesFingerprint(session: BuildSession, instances: Node[] | null): string {
	if (instances == null) return "";
	let joined = "";
	for (const node of instances) joined = joined + instanceFingerprint(session, node) + ";";
	return joined;
}

export function hcrTypeLayouts(session: BuildSession, modules: HcrIndirectModule[]): HashMap<string, string> {
	const layouts = new HashMap<string, string>();
	for (const m of modules) {
		layouts.set(m.modulePath, m.moduleId + "|" + m.typeInfos.join(",") + "|" + m.typeKeys.join(",") + "\n" + projectTypesFingerprint(session, [m.modulePath]));
	}
	return layouts;
}


function isTypeDeclaration(kind: SymbolKind): boolean {
	return kind == SymbolKind.Class || kind == SymbolKind.Interface || kind == SymbolKind.TypeAlias
		|| kind == SymbolKind.Enum || kind == SymbolKind.Struct || kind == SymbolKind.Actor;
}

export function projectTypesFingerprint(session: BuildSession, paths: string[]): string {
	const shapes: string[] = [];
	for (const path of paths) {
		const ctx = session.check.checks.get(path);
		if (ctx == null || ctx.table == null || ctx.table.current == null) continue;
		for (const sym of ctx.table.current.symbols.values()) {
			if (sym.modulePath != path || !isTypeDeclaration(sym.symbolKind)) continue;
			shapes.push(path + "::" + sym.name + "=" + layoutDigest(session, sym.symbolType));
		}
	}
	shapes.sort();
	return shapes.join("\n");
}

import { NodeKind, createNodeAt, makeLoc } from "../ast/node";
import { makeSymbol } from "../checker/symbol";
import { int32Type, stringType, createStruct, createEnum, createTuple } from "../checker/types";

function slotReference(disamb: int32): Node {
	const sym = makeSymbol("slot", SymbolKind.Variable, int32Type(), false);
	sym.modulePath = "/m.ms";
	sym.disamb = disamb;
	const ref = createNodeAt(NodeKind.Identifier, { name: "slot" }, makeLoc(1, 1));
	ref.resolvedSym = sym;
	return ref;
}

test "an instance fingerprint tells two same-named symbols of one module apart" {
	const session = createBuildSession(true);
	assert instancesFingerprint(session, [slotReference(1)]) != instancesFingerprint(session, [slotReference(2)]);
}

function declared(t: Type, kind: SymbolKind): Type {
	const sym = makeSymbol(t.typeName, kind, t, false);
	sym.modulePath = "/m.ms";
	t.sym = sym;
	return t;
}

function classB(fieldType: Type): Type {
	return declared(createStruct("B", ["x"], [fieldType], false), SymbolKind.Class);
}

function instanceOver(arg: Type): Node {
	const sym = makeSymbol("f", SymbolKind.Function, int32Type(), false);
	sym.modulePath = "/m.ms";
	const generic = makeSymbol("f", SymbolKind.Function, null, false);
	generic.modulePath = "/g.ms";
	sym.instantiatedFrom = generic;
	sym.instanceArgs = [arg];
	const ref = createNodeAt(NodeKind.Identifier, { name: "f" }, makeLoc(1, 1));
	ref.resolvedSym = sym;
	return ref;
}

test "a type shape of a diamond chain stays flat" {
	const session = createBuildSession(true);
	let level = declared(createStruct("L0", ["v"], [int32Type()], false), SymbolKind.Class);
	for (let i = 1; i <= 14; i += 1) level = declared(createStruct("L" + String(i), ["a", "b"], [level, level], false), SymbolKind.Class);
	assert typeShape(session, level).length < 200;
}

test "an instance over a diamond chain fingerprints in linear size" {
	const session = createBuildSession(true);
	let level = declared(createStruct("L0", ["v"], [int32Type()], false), SymbolKind.Struct);
	level.typeFlags = level.typeFlags.incl(TypeFlag.IsStruct);
	for (let i = 1; i <= 14; i += 1) {
		level = declared(createStruct("L" + String(i), ["a", "b"], [level, level], false), SymbolKind.Struct);
		level.typeFlags = level.typeFlags.incl(TypeFlag.IsStruct);
	}
	assert instancesFingerprint(session, [instanceOver(level)]).length < 8000;
}

test "an instance fingerprint changes when the argument class changes a field type" {
	const session = createBuildSession(true);
	assert instancesFingerprint(session, [instanceOver(classB(int32Type()))]) != instancesFingerprint(session, [instanceOver(classB(stringType()))]);
}

test "an instance fingerprint changes when a by-value member of the argument changes" {
	const session = createBuildSession(true);
	const first = declared(createStruct("P", ["n"], [int32Type()], true), SymbolKind.Struct);
	first.typeFlags = first.typeFlags.incl(TypeFlag.IsStruct);
	const second = declared(createStruct("P", ["n"], [stringType()], true), SymbolKind.Struct);
	second.typeFlags = second.typeFlags.incl(TypeFlag.IsStruct);
	const a = declared(createStruct("B", ["p"], [first], false), SymbolKind.Class);
	const b = declared(createStruct("B", ["p"], [second], false), SymbolKind.Class);
	assert instancesFingerprint(session, [instanceOver(a)]) != instancesFingerprint(session, [instanceOver(b)]);
	assert instancesFingerprint(session, [instanceOver(createTuple([first]))]) != instancesFingerprint(session, [instanceOver(createTuple([second]))]);
}

test "an enum layout changes with a member name or a member value" {
	const session = createBuildSession(true);
	const base = declared(createEnum("E", ["A", "B"], [0, 1]), SymbolKind.Enum);
	const renamed = declared(createEnum("E", ["A", "C"], [0, 1]), SymbolKind.Enum);
	const revalued = declared(createEnum("E", ["A", "B"], [0, 2]), SymbolKind.Enum);
	assert layoutDigest(session, base) != layoutDigest(session, renamed);
	assert layoutDigest(session, base) != layoutDigest(session, revalued);
}
