// @stdout: a b c d e f g h i j
// note: a local that is an array keeps its objects to the end of its scope while a read through an Unowned edge that can reach one of them may still run there. Each function hands the array over at its last read to something that gives it up before the scope ends (a holder in an inner scope, a binding or a field overwritten, a `sink` parameter only read, a constructor's object that dies), then reads the edge: directly, in a callee, with a nullable array, an array of arrays, an array of objects that own the target, a `sink` array parameter. Before the fix the array moved at its last read, its objects died with the receiver and the read stopped on C and the Raiser with "an Unowned<P> edge was read after its P was destroyed" while JS printed.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; }
class Bag { items: P[] = []; }
class Keeper { items: P[]; constructor(items: P[]) { this.items = items; } }
class Grid { rows: P[][] = []; }
class Box { own: P | null = null; }
class Shelf { boxes: Box[] = []; }
function count(sink ps: P[]): int32 { return ps.length as int32; }
function peek(h: H): string { return h.up!.name; }

function holderInInnerScope(): string {
	const h = new H();
	const list: P[] = [new P("a")];
	h.up = list[0];
	{ const b = new Bag(); b.items = list; }
	return h.up!.name;
}

function bindingOverwritten(): string {
	const h = new H();
	const list: P[] = [new P("b")];
	h.up = list[0];
	let q: P[] | null = list;
	q = null;
	return h.up!.name;
}

function fieldOverwritten(): string {
	const h = new H();
	const b = new Bag();
	const list: P[] = [new P("c")];
	h.up = list[0];
	b.items = list;
	b.items = [];
	return h.up!.name;
}

function sinkParameterOnlyRead(): string {
	const h = new H();
	const list: P[] = [new P("d")];
	h.up = list[0];
	const n = count(list);
	return h.up!.name;
}

function constructorObjectDies(): string {
	const h = new H();
	const list: P[] = [new P("e")];
	h.up = list[0];
	{ const k = new Keeper(list); }
	return h.up!.name;
}

function readInACallee(): string {
	const h = new H();
	const list: P[] = [new P("f")];
	h.up = list[0];
	{ const b = new Bag(); b.items = list; }
	return peek(h);
}

function nullableArray(): string {
	const h = new H();
	let list: P[] | null = [new P("g")];
	h.up = list![0];
	{ const b = new Bag(); if (list != null) b.items = list; }
	return h.up!.name;
}

function arrayOfArrays(): string {
	const h = new H();
	const grid: P[][] = [[new P("h")]];
	h.up = grid[0][0];
	{ const g = new Grid(); g.rows = grid; }
	return h.up!.name;
}

function arrayOfOwners(): string {
	const h = new H();
	const boxes: Box[] = [new Box()];
	boxes[0].own = new P("i");
	h.up = boxes[0].own;
	{ const s = new Shelf(); s.boxes = boxes; }
	return h.up!.name;
}

function sinkArrayParameterOfTheCallee(sink list: P[], h: H): string {
	h.up = list[0];
	{ const b = new Bag(); b.items = list; }
	return h.up!.name;
}

function sinkArrayParameter(): string {
	const h = new H();
	return sinkArrayParameterOfTheCallee([new P("j")], h);
}

console.log([holderInInnerScope(), bindingOverwritten(), fieldOverwritten(), sinkParameterOnlyRead(), constructorObjectDies(), readInACallee(), nullableArray(), arrayOfArrays(), arrayOfOwners(), sinkArrayParameter()].join(" "));
