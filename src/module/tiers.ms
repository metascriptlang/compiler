import { Node, NodeKind, Symbol, SymbolKind, ProgramData, ExportDeclData, FunctionDeclData, ClassDeclData, VariableDeclData, ExternDeclData, DecoratedDeclData } from "../ast/node";
import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { exists, readFile } from "std/fs";
import { resolveRuntimeDir } from "../utils/path";

export const TIER_EXTENSIONS: string[] = [".cms", ".jms"];
export const TIER_NAMES: string[] = ["C", "JS"];

function declName(decl: Node): string {
	return match (decl.kind) {
		NodeKind.FunctionDecl => (decl.data as FunctionDeclData).fnName,
		NodeKind.ClassDecl => (decl.data as ClassDeclData).className,
		NodeKind.VariableDecl => (decl.data as VariableDeclData).declName,
		NodeKind.ExternDecl => (decl.data as ExternDeclData).externName,
		NodeKind.DecoratedDecl => declName((decl.data as DecoratedDeclData).decoratedNode),
		_ => "",
	};
}

function exportsName(path: string, name: string): boolean {
	const source = readFile(path);
	if (!source.ok) return false;
	const parsed = parseSource(source.value);
	if (!parsed.ok) return false;
	for (const stmt of (parsed.value.data as ProgramData).programStmts) {
		if (exportedName(stmt) == name) return true;
	}
	return false;
}

function exportedName(stmt: Node): string {
	if (stmt.kind == NodeKind.DecoratedDecl) return exportedName((stmt.data as DecoratedDeclData).decoratedNode);
	return stmt.kind == NodeKind.ExportDecl ? declName((stmt.data as ExportDeclData).exportedDecl) : "";
}

function stemOf(modulePath: string): string {
	const dot = modulePath.lastIndexOf(".");
	return dot > modulePath.lastIndexOf("/") ? modulePath.slice(0, dot) : modulePath;
}

export function tiersDeclaring(modulePath: string, name: string): string[] {
	const stem = stemOf(modulePath);
	const sharedByEveryBackend = modulePath.endsWith(".ms");
	const tiers: string[] = [];
	for (let i = 0; i < TIER_EXTENSIONS.length; i += 1) {
		const path = stem + TIER_EXTENSIONS[i];
		const declares = path == modulePath || exportsName(path, name) || (sharedByEveryBackend && !exists(path));
		if (declares) tiers.push(TIER_NAMES[i]);
	}
	return tiers;
}

let _stdRoot = "";

export function stdModuleName(modulePath: string): string {
	if (_stdRoot == "") _stdRoot = resolveRuntimeDir() + "/std/";
	if (!modulePath.startsWith(_stdRoot)) return "";
	let module = stemOf(modulePath.slice(_stdRoot.length));
	if (module.endsWith("/index")) module = module.slice(0, module.length - "/index".length);
	return `std/${module}`;
}

// The qualified name a host callback is registered under: the declaring module and the declared
// name, with no signature, so one callback serves every overload and every instance of a generic.
export function hostRoutineKey(sym: Symbol): string {
	const origin = sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
	if (origin.symbolKind != SymbolKind.Function || origin.modulePath == "") return "";
	const module = stdModuleName(origin.modulePath);
	return module == "" ? "" : `${module}.${origin.name}`;
}

export function raiserRefusal(subject: string, reason: string, tiers: string[]): string {
	const where = tiers.length > 0 ? `; it runs on ${tiers.join(" and ")}` : "";
	return `${subject} cannot run on the Raiser: ${reason}${where}`;
}

test "tiersDeclaring names the C and JS tiers that export the routine and nothing for a name no tier has" {
	const std = resolveRuntimeDir() + "/std/";
	assert tiersDeclaring(std + "os/index.cms", "cpus").join(",") == "C";
	assert tiersDeclaring(std + "os/index.rms", "cpus").join(",") == "C";
	assert tiersDeclaring(std + "crypto/index.rms", "randomUUIDSync").join(",") == "C,JS";
	assert tiersDeclaring(std + "core/promise/index.rms", "spawn").join(",") == "C,JS";
	assert tiersDeclaring(std + "os/index.rms", "noSuchRoutine").length == 0;
	assert stdModuleName(std + "crypto/blake2b/index.cms") == "std/crypto/blake2b";
	assert stdModuleName("/elsewhere/os/index.cms") == "";
}
