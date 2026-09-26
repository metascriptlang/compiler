import { Node, Type, Symbol, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckSession, createCheckSession } from "../checker/orchestrator";
import { GenericTypeInstRow, takeGenericTypeInstsFrom } from "../parser/context";
import { pendingInstanceKeyOf } from "../checker/instantiate";
import { ModuleError } from "../module/graph";
import { monoTypeKey } from "../monomorphize/registry";
import { HcrIndirectModule } from "../transform/native/hcrIndirect";
import { taHashString, transAmHashNode } from "./transam/hash";

export enum BuildStatus {
	Built,
	UpToDate,
	Stale,
}

export interface LowerClaims {
	typeInfos: string[];
	hooks: Symbol[];
}

export function sameClaims(a: LowerClaims, b: LowerClaims): boolean {
	if (a.typeInfos.join(",") != b.typeInfos.join(",")) return false;
	if (a.hooks.length != b.hooks.length) return false;
	for (let i = 0; i < a.hooks.length; i += 1) {
		if (a.hooks[i].name != b.hooks[i].name) return false;
	}
	return true;
}

export class BuildSession {
	keep: boolean;
	check: CheckSession;
	lowerFingerprints: HashMap<string, string>;
	lowerDiagnostics: HashMap<string, ModuleError[]>;
	lowerClaims: HashMap<string, LowerClaims>;
	hcrTablesFingerprint: string;
	staleReason: string;
	moduleCount: int32;
	lastBuilt: boolean;
	loweredCount: int32;
	instanceFingerprints: HashMap<Node, string>;
	typeShapes: HashMap<Type, string>;
}

export function createBuildSession(keep: boolean): BuildSession {
	return {
		keep,
		check: createCheckSession(),
		lowerFingerprints: new HashMap<string, string>(),
		lowerDiagnostics: new HashMap<string, ModuleError[]>(),
		lowerClaims: new HashMap<string, LowerClaims>(),
		hcrTablesFingerprint: "",
		staleReason: "",
		moduleCount: 0,
		lastBuilt: false,
		loweredCount: 0,
		instanceFingerprints: new HashMap<Node, string>(),
		typeShapes: new HashMap<Type, string>(),
	};
}

export function startSessionBuild(session: BuildSession): void {
	session.staleReason = "";
	session.moduleCount = 0;
	session.loweredCount = 0;
	session.typeShapes = new HashMap<Type, string>();
}

function mix(h: number, value: number): number {
	return (h * 31 + value) % 2147483647;
}

function typeShapeWithin(t: Type | null, seen: HashSet<Type>): string {
	if (t == null) return "_";
	let shape = monoTypeKey(t);
	if (seen.has(t)) return shape;
	seen.add(t);
	if (t.typeNames != null && t.typeNames.length > 0) {
		shape = shape + "{";
		for (let i = 0; i < t.typeNames.length; i += 1) {
			const field = t.typeChildren != null && i < t.typeChildren.length ? t.typeChildren[i] : null;
			shape = shape + t.typeNames[i] + ":" + typeShapeWithin(field, seen) + ",";
		}
		shape = shape + "}";
	} else if (t.typeChildren != null) {
		for (const child of t.typeChildren) shape = shape + "(" + typeShapeWithin(child, seen) + ")";
	}
	if (t.typeReturn != null) shape = shape + ">" + typeShapeWithin(t.typeReturn, seen);
	seen.delete(t);
	return shape;
}

function typeShape(session: BuildSession, t: Type | null): string {
	if (t == null) return "_";
	const memo = session.typeShapes.get(t);
	if (memo != null) return memo;
	const shape = typeShapeWithin(t, new HashSet<Type>());
	session.typeShapes.set(t, shape);
	return shape;
}

function foldTypes(session: BuildSession, node: Node, h: number): number {
	let acc = h;
	if (node.nodeType != null) acc = mix(acc, taHashString(typeShape(session, node.nodeType)));
	const sym = node.resolvedSym;
	if (sym != null) acc = mix(acc, taHashString(sym.name + "|" + sym.modulePath + "|" + typeShape(session, sym.symbolType)));
	const children: Node[] = [];
	forEachChild(node, (child: Node): void => { children.push(child); });
	for (const child of children) acc = foldTypes(session, child, acc);
	return acc;
}

function instanceFingerprint(session: BuildSession, node: Node): string {
	const memo = session.instanceFingerprints.get(node);
	if (memo != null) return memo;
	const fingerprint = pendingInstanceKeyOf(node) + "#" + String(foldTypes(session, node, transAmHashNode(node)));
	session.instanceFingerprints.set(node, fingerprint);
	return fingerprint;
}

export function instancesFingerprint(session: BuildSession, instances: Node[] | null): string {
	if (instances == null) return "";
	let joined = "";
	for (const node of instances) joined = joined + instanceFingerprint(session, node) + ";";
	return joined;
}

export function hcrTablesFingerprint(modules: HcrIndirectModule[]): string {
	let out = "";
	for (const m of modules) {
		out = out + m.moduleId + "|" + m.abiKey + "|" + m.symbols.join(",") + "|" + m.typeInfos.join(",") + "|" + m.typeKeys.join(",");
		for (const imp of m.imports) out = out + "|" + imp.moduleId + "=" + imp.abiKey;
		out = out + "|" + m.beforeReload.join(",") + "|" + m.afterReload.join(",") + "\n";
	}
	return out;
}

export function collectTypeInstanceRows(check: CheckSession, loadOrder: string[]): GenericTypeInstRow[] {
	const lists: GenericTypeInstRow[][] = [check.preludeTypeInstances];
	for (const path of loadOrder) {
		const created = check.typeInstances.get(path);
		if (created != null) lists.push(created);
	}
	lists.push(takeGenericTypeInstsFrom(0));
	const rows: GenericTypeInstRow[] = [];
	const seen = new HashSet<string>();
	for (const list of lists) {
		for (const row of list) {
			const key = row.baseName + "|" + row.typeArgKey;
			if (seen.has(key)) continue;
			seen.add(key);
			rows.push(row);
		}
	}
	return rows;
}

export function typeInstanceRowsFingerprint(rows: GenericTypeInstRow[]): string {
	let out = "";
	for (const row of rows) out = out + row.key + "|" + row.fieldNames + "|" + row.fieldTypes + ";";
	return out;
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
			shapes.push(path + "::" + sym.name + "=" + typeShape(session, sym.symbolType));
		}
	}
	shapes.sort();
	return shapes.join("\n");
}
