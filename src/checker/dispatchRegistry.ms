import { Symbol } from "../ast/node";

export interface DispMethodEntry {
	classSym: Symbol;
	methodName: string;
	sym: Symbol;
	overloaded: boolean;
	version: int32;
}

export interface DispatchRecords {
	classSyms: Symbol[];
	methodNames: string[];
	methodSyms: Symbol[];
}

export type DispatchReadSink = (classSym: Symbol, methodName: string) => void;

export class DispatchRegistry {
	entries: DispMethodEntry[];
	byClass: HashMap<Symbol, DispMethodEntry[]>;
	bySym: HashMap<Symbol, DispMethodEntry>;
	capture: DispatchRecords | null;
	version: int32;
	readSink: DispatchReadSink | null;
	seeded: HashSet<DispatchRecords>;
}

export function createDispatchRegistry(): DispatchRegistry {
	return {
		entries: [],
		byClass: new HashMap<Symbol, DispMethodEntry[]>(),
		bySym: new HashMap<Symbol, DispMethodEntry>(),
		capture: null,
		version: 0,
		readSink: null,
		seeded: new HashSet<DispatchRecords>(),
	};
}

export function copyDispatchRegistry(source: DispatchRegistry): DispatchRegistry {
	if (source.readSink != null) {
		throw new Error("internal: cannot copy dispatch during a cached query");
	}
	const copy = createDispatchRegistry();
	const entries = new HashMap<DispMethodEntry, DispMethodEntry>();
	for (const entry of source.entries) {
		const item: DispMethodEntry = {
			classSym: entry.classSym,
			methodName: entry.methodName,
			sym: entry.sym,
			overloaded: entry.overloaded,
			version: entry.version,
		};
		entries.set(entry, item);
		copy.entries.push(item);
		const ofClass = copy.byClass.get(item.classSym);
		if (ofClass != null) ofClass.push(item);
		else copy.byClass.set(item.classSym, [item]);
	}
	source.bySym.forEach((entry: DispMethodEntry, sym: Symbol): void => {
		copy.bySym.set(sym, entries.get(entry)!);
	});
	copy.version = source.version;
	for (const seed of source.seeded) copy.seeded.add(seed);
	return copy;
}
