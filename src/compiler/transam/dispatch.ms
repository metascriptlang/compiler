import { Symbol, SymbolKind } from "../../ast/node";
import {
	DispMethodEntry, DispatchReadSink, dispatchRegistryEntries,
	dispatchRegistryVersion, dispatchOverrideTable, installDispatchReadSink,
	resetDispatchRegistry, dispatchRecordMethod, dispatchOverridesFor,
} from "../../checker/context";
import { makeSymbol, symbolKey } from "../../checker/symbol";
import {
	createStruct, createRef, createFunction, stringType,
} from "../../checker/types";
import { dispatchDigest } from "./digest";
import {
	TaCacheStore, cacheGet, createCacheStore, cacheInvalidateReaders,
} from "./cache";
import {
	TaFileInputStore, getFileId, createFileInputStore, setFileText,
} from "./fileInput";
import {
	TaDependencyStack, pushFrame, popFrame, recordDependency,
	recordDurability, createDependencyStack,
} from "./query";
import { executeQueryWith } from "./redGreen";
import { TaQueryKind, TaDurability, createQueryKey } from "./revision";

class TaDispatchRow {
	version: int32;
	output: string;
	modules: string[];
}

export class TaDispatchStore {
	revision: int32;
	version: int32;
	facts: HashMap<DispMethodEntry, TaDispatchRow>;
	families: HashMap<string, TaDispatchRow>;
	queries: HashMap<string, int32>;
	outputs: HashMap<string, string>;
}

export function createDispatchStore(): TaDispatchStore {
	return {
		revision: -1,
		version: -1,
		facts: new HashMap<DispMethodEntry, TaDispatchRow>(),
		families: new HashMap<string, TaDispatchRow>(),
		queries: new HashMap<string, int32>(),
		outputs: new HashMap<string, string>(),
	};
}

function familyKey(classSym: Symbol, methodName: string): string {
	const owner = symbolKey(classSym);
	return `${owner.length}:${owner}${methodName.length}:${methodName}`;
}

function publishFamily(
	store: TaDispatchStore,
	name: string,
	id: int32,
	cache: TaCacheStore,
	inputs: TaFileInputStore,
	stack: TaDependencyStack,
): void {
	const key = createQueryKey(TaQueryKind.Dispatch, id);
	const row = store.families.get(name);
	const output = row != null ? row.output : "";
	const previous = cacheGet(cache, key);
	const equal = store.outputs.get(name) == output;
	const changedAt = previous != null && equal
		? previous.changedAt : store.revision;
	if (!equal) {
		cacheInvalidateReaders(cache, key);
	}
	pushFrame(stack, key);
	if (row != null) {
		for (const path of row.modules) {
			const fileId = getFileId(inputs, path);
			if (fileId < 0) continue;
			const check = createQueryKey(TaQueryKind.TypeCheck, fileId);
			if (cacheGet(cache, check) != null) recordDependency(stack, check);
		}
	}
	recordDurability(stack, TaDurability.Low);
	executeQueryWith(cache, inputs, stack, key,
		store.revision, changedAt, true);
	store.outputs.set(name, output);
}

export function prepareDispatch(
	store: TaDispatchStore,
	cache: TaCacheStore,
	inputs: TaFileInputStore,
	stack: TaDependencyStack,
	revision: int32,
): void {
	const version = dispatchRegistryVersion();
	if (store.revision == revision && store.version == version) return;
	const facts = new HashMap<DispMethodEntry, TaDispatchRow>();
	const bySym = new HashMap<Symbol, TaDispatchRow>();
	const entries = dispatchRegistryEntries();
	for (const entry of entries) {
		const known = store.facts.get(entry);
		const row: TaDispatchRow = known != null &&
			known.version == entry.version ? known : {
				version: entry.version,
				output: dispatchDigest([entry]),
				modules: [entry.classSym.modulePath, entry.sym.modulePath],
			};
		facts.set(entry, row);
		bySym.set(entry.sym, row);
	}
	store.facts = facts;
	store.families = new HashMap<string, TaDispatchRow>();
	const overrides = dispatchOverrideTable();
	for (const entry of entries) {
		const own = facts.get(entry)!;
		let output = `${own.output.length}:${own.output}`;
		const modules = new HashSet<string>();
		for (const path of own.modules) modules.add(path);
		const children = overrides.get(entry.sym);
		if (children != null) {
			for (const child of children) {
				const row = bySym.get(child);
				if (row == null) {
					throw new Error("internal: override has no checked dispatch row");
				}
				output += `${row.output.length}:${row.output}`;
				for (const path of row.modules) modules.add(path);
			}
		}
		const paths: string[] = [];
		for (const path of modules) paths.push(path);
		store.families.set(familyKey(entry.classSym, entry.methodName), {
			version,
			output,
			modules: paths,
		});
	}
	store.revision = revision;
	store.version = version;
	for (const [name, id] of store.queries) {
		publishFamily(store, name, id, cache, inputs, stack);
	}
}

export function trackDispatchReads(
	store: TaDispatchStore,
	cache: TaCacheStore,
	inputs: TaFileInputStore,
	stack: TaDependencyStack,
): DispatchReadSink | null {
	const read = new HashSet<string>();
	return installDispatchReadSink((owner: Symbol, method: string): void => {
		if (store.version != dispatchRegistryVersion()) {
			throw new Error("internal: dispatch changed during a cached query");
		}
		const name = familyKey(owner, method);
		if (read.has(name)) return;
		read.add(name);
		const known = store.queries.get(name);
		const id = known != null ? known : store.queries.size;
		if (known == null) store.queries.set(name, id);
		const key = createQueryKey(TaQueryKind.Dispatch, id);
		const entry = cacheGet(cache, key);
		if (entry == null || entry.verifiedAt != store.revision) {
			publishFamily(store, name, id, cache, inputs, stack);
		}
		recordDependency(stack, key);
		recordDurability(stack, TaDurability.Low);
	});
}

test "a dispatch read records even an empty override set" {
	resetDispatchRegistry();
	const store = createDispatchStore();
	const cache = createCacheStore(20);
	const inputs = createFileInputStore();
	const stack = createDependencyStack();
	const body = createStruct("Base", [], [], true);
	const base = makeSymbol("Base", SymbolKind.Class, createRef(body), false);
	base.modulePath = "/dispatch/base.ms";
	body.sym = base;
	setFileText(inputs, base.modulePath, "base", 1);
	prepareDispatch(store, cache, inputs, stack, 1);
	const lower = createQueryKey(TaQueryKind.Lower, 0);
	pushFrame(stack, lower);
	const outer = trackDispatchReads(store, cache, inputs, stack);
	assert dispatchOverridesFor(base, "name").length == 0;
	assert dispatchOverridesFor(base, "name").length == 0;
	installDispatchReadSink(outer);
	const frame = popFrame(stack);
	assert frame.deps.length == 1;
	const query = frame.deps[0];
	assert query.queryKind == TaQueryKind.Dispatch;
	const method = makeSymbol("Base_name", SymbolKind.Function,
		createFunction([base.symbolType!], ["this"], stringType()), false);
	method.modulePath = base.modulePath;
	dispatchRecordMethod(base, "name", method);
	prepareDispatch(store, cache, inputs, stack, 2);
	assert cacheGet(cache, query)!.changedAt == 2;
	dispatchRecordMethod(base, "name", method);
	prepareDispatch(store, cache, inputs, stack, 3);
	assert cacheGet(cache, query)!.changedAt == 2;
	resetDispatchRegistry();
	prepareDispatch(store, cache, inputs, stack, 4);
	assert cacheGet(cache, query)!.changedAt == 4;
	assert stack.frames.length == 0;
}

test "another method family leaves a checked snapshot unchanged" {
	resetDispatchRegistry();
	const store = createDispatchStore();
	const cache = createCacheStore(20);
	const inputs = createFileInputStore();
	const stack = createDependencyStack();
	const body = createStruct("Base", [], [], true);
	const base = makeSymbol("Base", SymbolKind.Class, createRef(body), false);
	base.modulePath = "/dispatch/base.ms";
	body.sym = base;
	const method = makeSymbol("Base_name", SymbolKind.Function,
		createFunction([base.symbolType!], ["this"], stringType()), false);
	method.modulePath = base.modulePath;
	dispatchRecordMethod(base, "name", method);
	prepareDispatch(store, cache, inputs, stack, 1);
	pushFrame(stack, createQueryKey(TaQueryKind.Lower, 0));
	const outer = trackDispatchReads(store, cache, inputs, stack);
	dispatchOverridesFor(base, "name");
	installDispatchReadSink(outer);
	const key = popFrame(stack).deps[0];
	const before = cacheGet(cache, key)!.changedAt;
	method.mutatedParams = 7;
	const otherBody = createStruct("Other", [], [], true);
	const other = makeSymbol("Other", SymbolKind.Class,
		createRef(otherBody), false);
	other.modulePath = "/dispatch/other.ms";
	otherBody.sym = other;
	const otherMethod = makeSymbol("Other_name", SymbolKind.Function,
		createFunction([other.symbolType!], ["this"], stringType()), false);
	otherMethod.modulePath = other.modulePath;
	dispatchRecordMethod(other, "name", otherMethod);
	prepareDispatch(store, cache, inputs, stack, 2);
	assert cacheGet(cache, key)!.changedAt == before;
	assert cacheGet(cache, key)!.verifiedAt == 2;
	resetDispatchRegistry();
}

test "dispatch mutation and untracked snapshots in a query fail loud" {
	for (const snapshot of [false, true]) {
		resetDispatchRegistry();
		const store = createDispatchStore();
		const cache = createCacheStore(20);
		const inputs = createFileInputStore();
		const stack = createDependencyStack();
		prepareDispatch(store, cache, inputs, stack, 1);
		pushFrame(stack, createQueryKey(TaQueryKind.Lower, 0));
		const outer = trackDispatchReads(store, cache, inputs, stack);
		let message = "";
		try {
			if (snapshot) dispatchRegistryEntries();
			else resetDispatchRegistry();
		} catch (e) {
			message = (e as Error).message;
		} finally {
			installDispatchReadSink(outer);
			popFrame(stack);
		}
		assert message == (snapshot
			? "internal: untracked dispatch snapshot during a cached query"
			: "internal: dispatch changed during a cached query");
	}
}
