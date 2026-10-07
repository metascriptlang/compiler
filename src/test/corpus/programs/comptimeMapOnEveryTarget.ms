// @stdout: total=1 weighted=44 hashed=7 keys=a,bb
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
