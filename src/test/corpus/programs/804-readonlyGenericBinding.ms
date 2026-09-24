// @stdout: id=1 push=1 first=1 plain=5

// A type parameter bound to a `Readonly<T>` view keeps the view, and the mutable
// instantiation of the same generic stays writable after the read-only one.
interface N { k: int32; }

function id<T>(x: T): T { return x; }
function pushG<T>(arr: T[], v: T): void { arr.push(v); }
function first<T>(arr: T[]): T { return arr[0]; }
function readK(ro: Readonly<N>): int32 { return ro.k; }

function viaId(ro: Readonly<N>): int32 { return readK(id(ro)); }

function viaPush(ro: Readonly<N>): int32 {
	const xs: Readonly<N>[] = [];
	pushG(xs, ro);
	return xs.length;
}

function viaFirst(ros: Readonly<N>[]): int32 { return readK(first(ros)); }

function plain(n: N): int32 {
	const r = id(n);
	r.k = 5;
	return r.k;
}

export function main(): void {
	const a: N = { k: 1 };
	const i = viaId(a);
	const p = viaPush(a);
	const f = viaFirst([a]);
	console.log(`id=${i} push=${p} first=${f} plain=${plain(a)}`);
}

main();
