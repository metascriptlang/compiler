// @skip-js: C-only by design: onDestroy counts the frees the DRC makes; JS has no destructors
// @stdout: HashMap delete: 40 of 40 released at once, 40 alive
// @stdout: HashMap clear: 40 released at once, 0 alive
// @stdout: HashSet delete: 40 of 40 released at once, 40 alive
// @stdout: HashSet clear: 40 released at once, 0 alive
// @stdout: Map delete: 40 of 40 released at once, 40 alive
// @stdout: Map clear: 40 released at once, 0 alive
// @stdout: Set delete: 40 of 40 released at once, 40 alive
// @stdout: Set clear: 40 released at once, 0 alive
// note: delete releases the removed key or value before the statement ends, the moved-back neighbours of a collision run included, and clear releases every entry, so a value nothing else holds is destroyed by that call, not when its slot is reused.
let destroyed = 0;

class V {
	id: int32 = 0;
	constructor(id: int32) { this.id = id; }
	onDestroy(): void { destroyed += 1; }
}

function deleted(kind: string, atOnce: int32, alive: int32): void {
	console.log(`${kind} delete: ${atOnce} of 40 released at once, ${alive} alive`);
}

function cleared(kind: string, before: int32, alive: int32): void {
	console.log(`${kind} clear: ${destroyed - before} released at once, ${alive} alive`);
}

function deleteLast(s: HashSet<V>, keys: V[]): void {
	s.delete(keys.pop());
}

function deleteLast(s: Set<V>, keys: V[]): void {
	s.delete(keys.pop());
}

function hashMap(): void {
	const m = new HashMap<int32, V>();
	for (let i = 0; i < 80; i += 1) m.set(i, new V(i));
	let atOnce = 0;
	for (let i = 0; i < 80; i += 2) {
		const before = destroyed;
		m.delete(i);
		if (destroyed - before == 1) atOnce += 1;
	}
	deleted("HashMap", atOnce, m.size);
	const before = destroyed;
	m.clear();
	cleared("HashMap", before, m.size);
}

function hashSet(): void {
	const s = new HashSet<V>();
	const evens: V[] = [];
	for (let i = 0; i < 80; i += 1) {
		const v = new V(i);
		if (i % 2 == 0) evens.push(v);
		s.add(v);
	}
	let atOnce = 0;
	while (evens.length > 0) {
		const before = destroyed;
		deleteLast(s, evens);
		if (destroyed - before == 1) atOnce += 1;
	}
	deleted("HashSet", atOnce, s.size);
	const before = destroyed;
	s.clear();
	cleared("HashSet", before, s.size);
}

function map(): void {
	const m = new Map<int32, V>();
	for (let i = 0; i < 80; i += 1) m.set(i, new V(i));
	let atOnce = 0;
	for (let i = 0; i < 80; i += 2) {
		const before = destroyed;
		m.delete(i);
		if (destroyed - before == 1) atOnce += 1;
	}
	deleted("Map", atOnce, m.size);
	const before = destroyed;
	m.clear();
	cleared("Map", before, m.size);
}

function set(): void {
	const s = new Set<V>();
	const evens: V[] = [];
	for (let i = 0; i < 80; i += 1) {
		const v = new V(i);
		if (i % 2 == 0) evens.push(v);
		s.add(v);
	}
	let atOnce = 0;
	while (evens.length > 0) {
		const before = destroyed;
		deleteLast(s, evens);
		if (destroyed - before == 1) atOnce += 1;
	}
	deleted("Set", atOnce, s.size);
	const before = destroyed;
	s.clear();
	cleared("Set", before, s.size);
}

hashMap();
hashSet();
map();
set();
