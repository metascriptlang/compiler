// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// @serial
// @stdout: witnesses 0
// @stdout: held 1
// @stdout: module 1 alias 1 array 1 refs 1
// note: a spawn result nobody awaits is destroyed once with its future, for a module-level handle, an alias of it, a `Promise<T>[]`, a local array of handles dropped while its slow worker still runs, and a result that is an array of refs (old compiler: the SAN ledger shows ModBox, AliasBox, ArrBox, SlowBox and RefBox allocated and never destroyed). One class per shape, so the ledger row names the shape that leaked; `witnesses` destroys one instance of each class, because the SAN lane checks balance only for a type with at least one destroy.

class ModBox { v: int32; constructor(v: int32) { this.v = v; } }
class AliasBox { v: int32; constructor(v: int32) { this.v = v; } }
class ArrBox { v: int32; constructor(v: int32) { this.v = v; } }
class SlowBox { v: int32; constructor(v: int32) { this.v = v; } }
class RefBox { v: int32; constructor(v: int32) { this.v = v; } }

function slow(): SlowBox {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 20000000; i += 1) { s = (s + i) % 1000; }
	return new SlowBox(s);
}

function dropBeforeSettle(): void {
	const hs: Promise<SlowBox>[] = [spawn(() => slow())];
	console.log(`held ${hs.length}`);
}

function witnesses(): int32 {
	const m = new ModBox(0);
	const a = new AliasBox(0);
	const r = new ArrBox(0);
	const s = new SlowBox(0);
	const f = new RefBox(0);
	return m.v + a.v + r.v + s.v + f.v;
}

console.log(`witnesses ${witnesses()}`);
const moduleHandle = spawn(() => new ModBox(1));
const aliased = spawn(() => new AliasBox(2));
const alias: Promise<AliasBox> = aliased;
const handles: Promise<ArrBox>[] = [spawn(() => new ArrBox(3))];
const refHandles: Promise<RefBox[]>[] = [spawn(() => [new RefBox(4), new RefBox(5)])];
dropBeforeSettle();
console.log(`module 1 alias 1 array ${handles.length} refs ${refHandles.length}`);
