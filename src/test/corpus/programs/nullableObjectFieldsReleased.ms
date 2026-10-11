// @stdout: control=4 inline=4 text=a named=4 deep=4 array=2 local=4 assigned=4 field=6 module=4
// note: an object literal stored where `{ ... } | null` is expected keeps its own object type, so releasing it releases what its fields hold. The ledger balances for an inline shape, a string field, a named shape, three levels deep, an array element, a function local, an assignment, a class field and a module constant. `control` releases each inner shape once on its own, so the ledger counts destroys for every type it checks.

interface Inline { inner: { deep: { v: int32 } } | null }
interface Text { inner: { deep: { s: string } | null } | null }
interface Named { v: int32 }
interface ByName { inner: { deep: Named | null } | null }
interface Deep { a: { b: { c: { v: int32 } } | null } | null }
class Box { inner: { deep: { v: int32 } } | null = null; }

function inline(): int32 {
	const d: Inline = { inner: { deep: { v: 4 } } };
	return d.inner?.deep.v ?? 0;
}

function text(): string {
	const d: Text = { inner: { deep: { s: "a" } } };
	return d.inner?.deep?.s ?? "-";
}

function named(): int32 {
	const d: ByName = { inner: { deep: { v: 4 } } };
	return d.inner?.deep?.v ?? 0;
}

function deep(): int32 {
	const d: Deep = { a: { b: { c: { v: 4 } } } };
	return d.a?.b?.c.v ?? 0;
}

function array(): int32 {
	const xs: ({ deep: { v: int32 } } | null)[] = [{ deep: { v: 4 } }, null];
	return xs.length;
}

function local(): int32 {
	const x: { deep: { v: int32 } } | null = { deep: { v: 4 } };
	return x?.deep.v ?? 0;
}

function assigned(): int32 {
	let x: { deep: { v: int32 } } | null = null;
	x = { deep: { v: 4 } };
	return x?.deep.v ?? 0;
}

function field(): int32 {
	const b = new Box();
	b.inner = { deep: { v: 5 } };
	b.inner = { deep: { v: 6 } };
	return b.inner?.deep.v ?? 0;
}

function control(): int32 {
	const v: { v: int32 } = { v: 1 };
	const s: { s: string } = { s: "b" };
	const n: Named = { v: 1 };
	const c: { c: { v: int32 } } = { c: { v: 1 } };
	return v.v + s.s.length + n.v + c.c.v;
}

const held: { deep: { v: int32 } } | null = { deep: { v: 4 } };

console.log(`control=${control()} inline=${inline()} text=${text()} named=${named()} deep=${deep()} array=${array()} local=${local()} assigned=${assigned()} field=${field()} module=${held?.deep.v ?? 0}`);
