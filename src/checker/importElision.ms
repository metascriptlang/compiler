import { ModuleGraph, ImportEntry } from "../module/graph";
import { Node, NodeKind, NodeFlag, Symbol, SymbolKind, ProgramData, ImportDeclData, ExportDeclData, FunctionDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { lookupModuleCtx, lookupModuleProgram } from "./instantiate";
import { CheckerContext, findExportedSymbol, isLifecycleHookName } from "./context";
import { lookupSymbol } from "./symbol";

interface RuntimeUse {
	syms: HashSet<Symbol>;
	modules: HashSet<string>;
}

function runtimeUseOf(program: Node, modulePath: string): RuntimeUse {
	const use: RuntimeUse = { syms: new HashSet<Symbol>(), modules: new HashSet<string>() };
	const visit = (n: Node): void => {
		const sym = n.resolvedSym;
		if (sym != null) {
			use.syms.add(sym);
			if (sym.modulePath != "" && sym.modulePath != modulePath && runsCodeOf(sym)) use.modules.add(sym.modulePath);
		}
		forEachChild(n, visit);
	};
	visit(program);
	return use;
}

function runsCodeOf(sym: Symbol): boolean {
	return !namesOnlyAType(sym) && sym.symbolKind != SymbolKind.Property;
}

function namesOnlyAType(sym: Symbol): boolean {
	const k = sym.symbolKind;
	return k == SymbolKind.Interface || k == SymbolKind.TypeAlias || k == SymbolKind.Struct;
}

function elidableBinding(sym: Symbol | null, use: RuntimeUse, reexport: boolean): boolean {
	if (sym == null) return false;
	if (reexport) return namesOnlyAType(sym);
	if (use.syms.has(sym)) return false;
	const k = sym.symbolKind;
	return namesOnlyAType(sym) || k == SymbolKind.Class || k == SymbolKind.Module;
}

function runsImplicitCode(program: Node): boolean {
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = stmt;
		if (decl != null && decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
		if (decl == null) continue;
		if (decl.kind == NodeKind.FunctionDecl && isLifecycleHookName((decl.data as FunctionDeclData).fnName)) return true;
		if (decl.kind == NodeKind.MacroDecl && decl.flags.has(NodeFlag.Converter)) return true;
	}
	return false;
}

interface ImportSite {
	decl: Node;
	reexport: boolean;
}

function importsOf(program: Node): ImportSite[] {
	const decls: ImportSite[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt == null) continue;
		if (stmt.kind == NodeKind.ImportDecl) decls.push({ decl: stmt, reexport: false });
		if (stmt.kind == NodeKind.ExportDecl) {
			const inner = (stmt.data as ExportDeclData).exportedDecl;
			if (inner != null && inner.kind == NodeKind.ImportDecl) decls.push({ decl: inner, reexport: true });
		}
	}
	return decls;
}

function sameBindings(entry: ImportEntry, d: ImportDeclData): boolean {
	return entry.sourceSpecifier == d.importSource && entry.names.join(",") == d.importNames.join(",") && entry.aliases.join(",") == d.importAliases.join(",");
}

function typeOnlyEntry(entry: ImportEntry, reexport: boolean, ctx: CheckerContext, use: RuntimeUse, stdPath: string, implicit: HashMap<string, boolean>): boolean {
	if (entry.dynamic || entry.names.length == 0) return false;
	if (entry.aliases.length == 1 && entry.aliases[0] == "*") return false;
	if (stdPath != "" && entry.sourcePath.startsWith(stdPath)) return false;
	const target = lookupModuleProgram(entry.sourcePath);
	if (target == null) return false;
	if (!implicit.has(entry.sourcePath)) implicit.set(entry.sourcePath, runsImplicitCode(target));
	if (implicit.get(entry.sourcePath)) return false;
	for (let i = 0; i < entry.names.length; i += 1) {
		const bound = entry.names[i] == "*" ? lookupSymbol(ctx.table, entry.aliases[i]) : null;
		const exported = findExportedSymbol(ctx.exportRegistry, entry.sourcePath, entry.names[i]);
		const sym = bound ?? (exported != null ? exported.sym : null);
		if (!elidableBinding(sym, use, reexport)) return false;
	}
	return true;
}

export function markTypeOnlyImports(graph: ModuleGraph, stdPath: string): void {
	const implicit = new HashMap<string, boolean>();
	for (const mod of graph.modules) {
		mod.runtimeDeps = [];
		for (let i = 0; i < mod.imports.length; i += 1) mod.imports[i].typeOnly = false;
		if (stdPath != "" && mod.path.startsWith(stdPath)) continue;
		const program = lookupModuleProgram(mod.path);
		const ctx = lookupModuleCtx(mod.path);
		if (program == null || ctx == null) continue;
		const use = runtimeUseOf(program, mod.path);
		const dynamicTargets: string[] = [];
		for (const entry of mod.imports) if (entry.dynamic) dynamicTargets.push(entry.sourcePath);
		for (const path of use.modules) if (!dynamicTargets.includes(path)) mod.runtimeDeps.push(path);
		const decls = importsOf(program);
		for (let i = 0; i < mod.imports.length; i += 1) {
			const entry = mod.imports[i];
			const sites: Node[] = [];
			let reexport = false;
			for (const site of decls) {
				if (!sameBindings(entry, site.decl.data as ImportDeclData)) continue;
				sites.push(site.decl);
				if (site.reexport) reexport = true;
			}
			if (!typeOnlyEntry(entry, reexport, ctx, use, stdPath, implicit)) continue;
			mod.imports[i].typeOnly = true;
			for (const decl of sites) decl.flags = decl.flags.incl(NodeFlag.TypeOnlyImport);
		}
	}
}
