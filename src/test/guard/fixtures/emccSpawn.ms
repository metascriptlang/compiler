struct Pt { tag: string; n: int32; }

function sq(n: int32): int32 { return n * n; }
function mkPt(n: int32): Pt { return { tag: "pt", n: n }; }
function label(n: int32): string { return "item" + n.toString(); }

function syncAwait(n: int32): int32 {
	return await spawn(() => sq(n));
}

async function asyncAwait(n: int32): Promise<int32> {
	const v = await spawn(() => sq(n));
	return v + 1;
}

function results(): string {
	const p = await spawn(() => mkPt(4));
	const s = await spawn(() => label(9));
	return `${p.tag}${p.n} ${s}`;
}

function group(): int32 {
	const rs = await Promise.all([spawn(() => sq(1)), spawn(() => sq(2)), spawn(() => sq(3))]);
	return rs[0] + rs[1] + rs[2];
}

function nested(n: int32): int32 {
	return await spawn(() => {
		const inner = await spawn(() => sq(n));
		return inner + 1;
	});
}

console.log(syncAwait(7));
console.log(await asyncAwait(5));
console.log(results());
console.log(group());
console.log(nested(6));

async function asyncResults(): Promise<string> {
	const p = await spawn(() => mkPt(8));
	const s = await spawn(() => label(2));
	return `${p.tag}${p.n} ${s}`;
}

async function asyncGroup(): Promise<int32> {
	const rs = await Promise.all([spawn(() => sq(4)), spawn(() => sq(5))]);
	return rs[0] + rs[1];
}

async function asyncNested(n: int32): Promise<int32> {
	return await spawn(() => {
		const inner = await spawn(() => sq(n));
		return inner + 2;
	});
}

function boom(): int32 { throw new Error("boom"); }

function failing(): string {
	try { return `${await spawn(() => boom())}`; } catch (e) { return "caught " + e.message; }
}

console.log(await asyncResults());
console.log(await asyncGroup());
console.log(await asyncNested(3));
console.log(failing());
