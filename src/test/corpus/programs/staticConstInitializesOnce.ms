// @stdout: static=1,1 method=2,2 loop=3 builds=3
// note: a `static const` has module-scope storage, so its initializer runs once however often the function, the method or the loop body that declares it runs, on every backend and in the compile-time VM.
let builds: int32 = 0;
function mk(): int32 { builds = builds + 1; return builds; }
function once(): int32 { static const v = mk(); return v; }

class K {
	get(): int32 { static const w = mk(); return w; }
}

const a = once();
const b = once();
const k = new K();
const c1 = k.get();
const c2 = k.get();
let loopSeen: int32 = 0;
for (let i = 0; i < 3; i += 1) {
	static const z = mk();
	loopSeen = z;
}
console.log(`static=${a},${b} method=${c1},${c2} loop=${loopSeen} builds=${builds}`);
