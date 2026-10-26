// @skip-js: the cycle collector exists only in the C runtime
// @stdout: generic-method=1 generic-function=1 depth2=1 generic-base=1
// note: a generic subclass built only from a dependent instantiation (`new Sub<V>` inside a generic method or function) must trace each inherited field once. A second traced edge per closure env balances an outside reference during the collection, and the collector frees live objects; a surviving slot proves every edge was counted once.

extern function msOrcCollect(): void;

class Cell { next: Cell | null = null; }

class Base { touch: () => void = (): void => {}; }
class Sub<V> extends Base {
	cell: Cell;
	value: V;
	constructor(value: V) {
		super();
		this.value = value;
		const cell = new Cell();
		this.cell = cell;
		this.touch = (): void => { cell.next = null; };
	}
}
class Holder<V> {
	slots: Base[] = [];
	add(value: V): void { this.slots.push(new Sub<V>(value)); }
}

class Mid extends Base { other: () => void = (): void => {}; }
class Deep<V> extends Mid {
	cell: Cell;
	value: V;
	constructor(value: V) {
		super();
		this.value = value;
		const cell = new Cell();
		this.cell = cell;
		this.touch = (): void => { cell.next = null; };
	}
}

class GBase<T> { touch: () => void = (): void => {}; held: T | null = null; }
class GSub<V> extends GBase<V> {
	cell: Cell;
	constructor() {
		super();
		const cell = new Cell();
		this.cell = cell;
		this.touch = (): void => { cell.next = null; };
	}
}

const method = new Holder<int32>();
method.add(5);
msOrcCollect();

const fnSlots: Base[] = [];
function make<V>(v: V): void { fnSlots.push(new Sub<V>(v)); }
make<int32>(5);
msOrcCollect();

const deepSlots: Base[] = [];
function makeDeep<V>(v: V): void { deepSlots.push(new Deep<V>(v)); }
makeDeep<int32>(5);
msOrcCollect();

const gSlots: GBase<int32>[] = [];
function makeG<V>(): void { gSlots.push(new GSub<V>() as unknown as GBase<int32>); }
makeG<int32>();
msOrcCollect();

console.log(`generic-method=${method.slots.length} generic-function=${fnSlots.length} depth2=${deepSlots.length} generic-base=${gSlots.length}`);
