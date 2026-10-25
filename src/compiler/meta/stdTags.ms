import { Symbol } from "../../ast/node";
import { ModuleGraph } from "../../module/graph";
import { lookupModuleCtx } from "../../checker/instantiate";
import { NamedSymbol, moduleScopeSymbols } from "../../checker/symbol";
import { ExportRegistry } from "../../checker/context";

export const metaNodeType = "$Node";
export const metaNodeKindType = "$NodeKind";
export const metaDeclKindType = "$DeclKind";
export const metaExternKindType = "$ExternKind";

const META_NODE_MODULE = "std/meta/node.ms";

const META_TYPE_TAGS: string[][] = [
	[metaNodeType, "MetaNode"],
	[metaNodeKindType, "MetaNodeKind"],
	[metaDeclKindType, "MetaDeclKind"],
	[metaExternKindType, "MetaExternKind"],
];

export function isMetaSeedName(name: string): boolean {
	for (const entry of META_TYPE_TAGS) if (entry[0] == name) return true;
	return false;
}

// One pass over the module scopes of the graph; a tag nothing in the graph carries stays null.
export function metaTagged(graph: ModuleGraph, tags: string[]): (Symbol | null)[] {
	const found: (Symbol | null)[] = [];
	for (let i = 0; i < tags.length; i += 1) found.push(null);
	let missing = tags.length;
	for (const path of graph.modulePaths) {
		const ctx = lookupModuleCtx(path);
		if (ctx == null) continue;
		for (const sym of moduleScopeSymbols(ctx.table)) {
			if (sym.builtinKind == "") continue;
			const at = tags.indexOf(sym.builtinKind);
			if (at < 0 || found[at] != null) continue;
			found[at] = sym;
			missing -= 1;
			if (missing == 0) return found;
		}
	}
	return found;
}

// The std/meta declarations the synthesized macro, decorator and comptime programs name, bound under
// names the compiler writes; a user spelling of Node, NodeKind or DeclKind never reaches them.
export function metaTypeSeeds(graph: ModuleGraph | null, registry: ExportRegistry | null): NamedSymbol[] {
	const seeds: NamedSymbol[] = [];
	const tags: string[] = [];
	for (const entry of META_TYPE_TAGS) tags.push(entry[1]);
	const found = graph != null ? metaTagged(graph, tags) : tags.map((_: string): Symbol | null => null);
	if (registry != null) fillFromMetaExports(registry, tags, found);
	for (let i = 0; i < META_TYPE_TAGS.length; i += 1) {
		const sym = found[i];
		if (sym != null) seeds.push({ name: META_TYPE_TAGS[i][0], sym: sym });
	}
	return seeds;
}

// A compilation outside any module graph still reaches std/meta through the modules it registered.
function fillFromMetaExports(registry: ExportRegistry, tags: string[], found: (Symbol | null)[]): void {
	for (const mod of registry.entries) {
		if (!mod.modulePath.endsWith(META_NODE_MODULE)) continue;
		for (const e of mod.symbols) {
			if (e.sym == null) continue;
			const at = tags.indexOf(e.sym.builtinKind);
			if (at >= 0 && found[at] == null) found[at] = e.sym;
		}
	}
}

export function seedsComplete(seeds: NamedSymbol[]): boolean {
	return seeds.length == META_TYPE_TAGS.length;
}
