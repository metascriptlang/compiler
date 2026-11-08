import { Symbol, BuiltinKind } from "../../ast/node";
import { ModuleGraph } from "../../module/graph";
import { lookupModuleCtx } from "../../checker/instantiate";
import { NamedSymbol, moduleScopeSymbols } from "../../checker/symbol";
import { CheckerContext } from "../../checker/context";

export const metaNodeType = "$Node";
export const metaNodeKindType = "$NodeKind";
export const metaDeclKindType = "$DeclKind";
export const metaExternKindType = "$ExternKind";

interface MetaTypeTag {
	seed: string;
	tag: BuiltinKind;
}

const META_TYPE_TAGS: MetaTypeTag[] = [
	{ seed: metaNodeType, tag: BuiltinKind.MetaNode },
	{ seed: metaNodeKindType, tag: BuiltinKind.MetaNodeKind },
	{ seed: metaDeclKindType, tag: BuiltinKind.MetaDeclKind },
	{ seed: metaExternKindType, tag: BuiltinKind.MetaExternKind },
];

export function isMetaSeedName(name: string): boolean {
	for (const entry of META_TYPE_TAGS) if (entry.seed == name) return true;
	return false;
}

// The module-scope symbols of `path`: its registered check, else the prelude's scope of it, because a
// module the prelude holds is checked there and never by the graph.
export function registeredModuleSymbols(path: string, prelude: CheckerContext | null = null): Symbol[] {
	const ctx = lookupModuleCtx(path);
	if (ctx != null) return moduleScopeSymbols(ctx.table);
	return prelude != null ? prelude.preludeModuleScopes.get(path) ?? [] : [];
}

// One pass over the module scopes of the graph; a tag nothing in the graph carries stays null.
export function metaTagged(graph: ModuleGraph, tags: BuiltinKind[]): (Symbol | null)[] {
	const found: (Symbol | null)[] = [];
	for (let i = 0; i < tags.length; i += 1) found.push(null);
	let missing = tags.length;
	for (const path of graph.modulePaths) {
		for (const sym of registeredModuleSymbols(path)) {
			if (sym.builtinKind == BuiltinKind.None) continue;
			const at = tags.indexOf(sym.builtinKind);
			if (at < 0 || found[at] != null) continue;
			found[at] = sym;
			missing -= 1;
			if (missing == 0) return found;
		}
	}
	return found;
}

// The std/meta declarations carrying `tags` as `ctx` reaches them: through its graph, else through the
// prelude, which holds std/meta when the graph leaves it to the prelude.
export function metaTaggedFor(graph: ModuleGraph | null, ctx: CheckerContext | null, tags: BuiltinKind[]): (Symbol | null)[] {
	const found = graph != null ? metaTagged(graph, tags) : tags.map((_: BuiltinKind): Symbol | null => null);
	if (ctx != null) fillFromPreludeModules(ctx, tags, found);
	if (ctx != null && ctx.preludeCtx != null) fillFromPreludeModules(ctx.preludeCtx, tags, found);
	return found;
}

// The std/meta declarations the synthesized macro, decorator and comptime programs name, bound under
// names the compiler writes; a user spelling of Node, NodeKind or DeclKind never reaches them.
export function metaTypeSeeds(graph: ModuleGraph | null, ctx: CheckerContext | null): NamedSymbol[] {
	const seeds: NamedSymbol[] = [];
	const tags: BuiltinKind[] = [];
	for (const entry of META_TYPE_TAGS) tags.push(entry.tag);
	const found = metaTaggedFor(graph, ctx, tags);
	for (let i = 0; i < META_TYPE_TAGS.length; i += 1) {
		const sym = found[i];
		if (sym != null) seeds.push({ name: META_TYPE_TAGS[i].seed, sym: sym });
	}
	return seeds;
}

// A compilation outside any module graph reaches std/meta through the prelude's module scopes.
function fillFromPreludeModules(ctx: CheckerContext, tags: BuiltinKind[], found: (Symbol | null)[]): void {
	for (const scope of ctx.preludeModuleScopes.values()) {
		for (const sym of scope) {
			const at = sym.builtinKind == BuiltinKind.None ? -1 : tags.indexOf(sym.builtinKind);
			if (at >= 0 && found[at] == null) found[at] = sym;
		}
	}
}

export function seedsComplete(seeds: NamedSymbol[]): boolean {
	return seeds.length == META_TYPE_TAGS.length;
}
