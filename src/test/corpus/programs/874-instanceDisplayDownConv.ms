// @stdout: deep=7 box=41 mid=1
// note: checked `as` out of `unknown` rides msObjDownConv → msIsInstance, now the display
// check; includes a generic class instance (one msTypeInfo per instantiation). Sibling of
// 646/647/873; the fatal direction is 875.

class B0 { id: number = 0; }
class B1 extends B0 {}
class B2 extends B1 {}
class B3 extends B2 {}
class B4 extends B3 {}
class B5 extends B4 {}
class Deep extends B5 { l: number = 7; }
class Mid extends B0 { m: number = 1; }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }

function deepOf(u: unknown): number {
	return (u as Deep).l;
}

function midOf(u: unknown): number {
	return (u as Mid).m;
}

function main(): void {
	const deep: unknown = new Deep();
	const mid: unknown = new Mid();
	const box: unknown = new Box<number>(41);
	console.log(`deep=${deepOf(deep)} box=${(box as Box<number>).v} mid=${midOf(mid)}`);
}
main();
