// @xfail(c): @comptime block: in instantiation of 'set<string, int32>': Ambiguous call to overloaded extension method 'push' (inbox 2026-10-06-comptime-map-fails-on-c-and-js-targets)
// @xfail(orc): @comptime block: in instantiation of 'set<string, int32>': Ambiguous call to overloaded extension method 'push' (inbox 2026-10-06-comptime-map-fails-on-c-and-js-targets)
// @xfail(danger): @comptime block: in instantiation of 'set<string, int32>': Ambiguous call to overloaded extension method 'push' (inbox 2026-10-06-comptime-map-fails-on-c-and-js-targets)
// @xfail(san): @comptime block: in instantiation of 'set<string, int32>': Ambiguous call to overloaded extension method 'push' (inbox 2026-10-06-comptime-map-fails-on-c-and-js-targets)
// @stdout: total=1 weighted=44 hashed=7 keys=a,bb
// note: a `Map` or `HashMap` inside `@comptime` folds the same as on `--target=raiser`: an on-demand std helper the engine compiles from the Raiser's std is checked with that std's own private declarations (before, a JS build stopped at `Undefined variable 'msMapFatal'`). A C build still instantiates the Raiser's `Map.set` in the C build's `struct` module and stops at an ambiguous `push`.
const total = @comptime {
	const m = new Map<string, int32>();
	m.set("a", 1);
	return m.size;
};
const weighted = @comptime {
	const m = new Map<string, int32>();
	m.set("a", 1);
	m.set("bb", 20);
	let acc = 0;
	for (const [k, v] of m) acc = acc + k.length * v;
	for (const k of m.keys()) acc = acc + k.length;
	return acc;
};
const hashed = @comptime {
	const h = new HashMap<string, int32>();
	h.set("x", 3);
	h.set("y", 4);
	return h.get("x")! + h.get("y")!;
};
const keys = @comptime {
	const m = new Map<string, boolean>();
	m.set("a", true);
	m.set("bb", false);
	return m.keys().join(",");
};
console.log("total=" + total.toString() + " weighted=" + weighted.toString() + " hashed=" + hashed.toString() + " keys=" + keys);
