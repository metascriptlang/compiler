// Fixture for handoff/crossModuleGenericCtor.ms — a generic class whose
// constructor must be instantiable from ANOTHER module. Deliberately contains
// no `new GcCell<...>` of its own for `boolean`/`GcTag`: the point of the guard
// is a specialization that only the importer ever asks for.

export class GcCell<T> {
	value: T;
	constructor(v: T) {
		this.value = v;
	}
}

export function gcMakeNumber(): GcCell<number> {
	return new GcCell<number>(41);
}
