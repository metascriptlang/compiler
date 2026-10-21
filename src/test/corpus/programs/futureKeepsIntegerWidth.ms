// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table (and no host bridge for msFutureThen)
// @serial
// @stdout: int64 3000000001 3000000001 3000000001 3000000001 3000000001 3000000001 3000000001
// @stdout: uint64 5000000003 5000000003 5000000003 5000000003 5000000003 5000000003 5000000003
// @stdout: int8 -5 -5 -5 -5 -5 -5
// @stdout: int16 -30000 -30000 -30000 -30000 -30000 -30000
// @stdout: uint16 60000 60000 60000 60000 60000 60000 60000
// @stdout: int32 -2147483648 -2147483648 -2147483648 -2147483648 -2147483648 -2147483648 -2147483648
// @stdout: uint32 4000000000 4000000000 4000000000 4000000000 4000000000 4000000000 4000000000
// @stdout: top 3000000001 5000000003
// note: an integer crosses a future at its own width on C, through an async return,
//   Promise.resolve, new Promise, Promise.all, spawn, an actor call and a .then callback
//   (int8/int16 leave out .then: inbox 2026-10-17-a-then-callback-gets-a-narrow-int-unextended).
//   Before the fix every await read a 64-bit integer as int32 (int64 3000000001 came back
//   -1294967295, uint64 5000000003 as 705032707), an unsigned await inside an async
//   function did not compile, and Promise.all of int8/int16/uint* futures crashed.

actor Holder {
	getI64(): int64 { const x: int64 = 3000000001; return x; }
	getU64(): uint64 { const x: uint64 = 5000000003; return x; }
	getI8(): int8 { const x: int8 = -5; return x; }
	getI16(): int16 { const x: int16 = -30000; return x; }
	getU16(): uint16 { const x: uint16 = 60000; return x; }
	getI32(): int32 { const x: int32 = -2147483648; return x; }
	getU32(): uint32 { const x: uint32 = 4000000000; return x; }
}

async function retI64(): Promise<int64> { const x: int64 = 3000000001; await sleepAsync(0); return x; }
async function retU64(): Promise<uint64> { const x: uint64 = 5000000003; await sleepAsync(0); return x; }
async function retI8(): Promise<int8> { const x: int8 = -5; await sleepAsync(0); return x; }
async function retI16(): Promise<int16> { const x: int16 = -30000; await sleepAsync(0); return x; }
async function retU16(): Promise<uint16> { const x: uint16 = 60000; await sleepAsync(0); return x; }
async function retI32(): Promise<int32> { const x: int32 = -2147483648; await sleepAsync(0); return x; }
async function retU32(): Promise<uint32> { const x: uint32 = 4000000000; await sleepAsync(0); return x; }

async function crossI64(h: Holder): Promise<string> {
	const x: int64 = 3000000001;
	const returned = await retI64();
	const resolved: Promise<int64> = Promise.resolve<int64>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<int64>((resolve) => { resolve(x); });
	const all = await Promise.all([retI64(), retI64()]);
	const spawned = await spawn((): int64 => x);
	const called = await h.getI64();
	let seen = "";
	await retI64().then((v: int64): void => { seen = `${v}`; });
	return `int64 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called} ${seen}`;
}
async function crossU64(h: Holder): Promise<string> {
	const x: uint64 = 5000000003;
	const returned = await retU64();
	const resolved: Promise<uint64> = Promise.resolve<uint64>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<uint64>((resolve) => { resolve(x); });
	const all = await Promise.all([retU64(), retU64()]);
	const spawned = await spawn((): uint64 => x);
	const called = await h.getU64();
	let seen = "";
	await retU64().then((v: uint64): void => { seen = `${v}`; });
	return `uint64 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called} ${seen}`;
}
async function crossI8(h: Holder): Promise<string> {
	const x: int8 = -5;
	const returned = await retI8();
	const resolved: Promise<int8> = Promise.resolve<int8>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<int8>((resolve) => { resolve(x); });
	const all = await Promise.all([retI8(), retI8()]);
	const spawned = await spawn((): int8 => x);
	const called = await h.getI8();
	return `int8 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called}`;
}
async function crossI16(h: Holder): Promise<string> {
	const x: int16 = -30000;
	const returned = await retI16();
	const resolved: Promise<int16> = Promise.resolve<int16>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<int16>((resolve) => { resolve(x); });
	const all = await Promise.all([retI16(), retI16()]);
	const spawned = await spawn((): int16 => x);
	const called = await h.getI16();
	return `int16 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called}`;
}
async function crossU16(h: Holder): Promise<string> {
	const x: uint16 = 60000;
	const returned = await retU16();
	const resolved: Promise<uint16> = Promise.resolve<uint16>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<uint16>((resolve) => { resolve(x); });
	const all = await Promise.all([retU16(), retU16()]);
	const spawned = await spawn((): uint16 => x);
	const called = await h.getU16();
	let seen = "";
	await retU16().then((v: uint16): void => { seen = `${v}`; });
	return `uint16 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called} ${seen}`;
}
async function crossI32(h: Holder): Promise<string> {
	const x: int32 = -2147483648;
	const returned = await retI32();
	const resolved: Promise<int32> = Promise.resolve<int32>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<int32>((resolve) => { resolve(x); });
	const all = await Promise.all([retI32(), retI32()]);
	const spawned = await spawn((): int32 => x);
	const called = await h.getI32();
	let seen = "";
	await retI32().then((v: int32): void => { seen = `${v}`; });
	return `int32 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called} ${seen}`;
}
async function crossU32(h: Holder): Promise<string> {
	const x: uint32 = 4000000000;
	const returned = await retU32();
	const resolved: Promise<uint32> = Promise.resolve<uint32>(x);
	const fromResolve = await resolved;
	const constructed = await new Promise<uint32>((resolve) => { resolve(x); });
	const all = await Promise.all([retU32(), retU32()]);
	const spawned = await spawn((): uint32 => x);
	const called = await h.getU32();
	let seen = "";
	await retU32().then((v: uint32): void => { seen = `${v}`; });
	return `uint32 ${returned} ${fromResolve} ${constructed} ${all[1]} ${spawned} ${called} ${seen}`;
}

const h = new Holder();
console.log(await crossI64(h));
console.log(await crossU64(h));
console.log(await crossI8(h));
console.log(await crossI16(h));
console.log(await crossU16(h));
console.log(await crossI32(h));
console.log(await crossU32(h));
const top: int64 = await retI64();
const topU: uint64 = await retU64();
console.log(`top ${top} ${topU}`);
