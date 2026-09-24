// @stdout: bang=123 as=123 bare=123

// A field read passed to a sink parameter is a borrow whatever wraps it: `!` and `as`
// are ownership-transparent, so the pushed element gets its own count and survives the
// owner's destroy. Junk allocations after the loop reuse any freed cell.
interface T2 { k: int32; }
interface FT { t: T2 | null; u: T2; }

function mk(v: int32): FT { return { t: { k: v }, u: { k: v } }; }

function fill(mode: int32): int32 {
	const xs: T2[] = [];
	for (let i = 0; i < 3; i = i + 1) {
		const ft = mk(i + 1);
		if (mode == 0) xs.push(ft.t!);
		else if (mode == 1) xs.push(ft.u as T2);
		else xs.push(ft.u);
	}
	const junk: T2[] = [];
	for (let i = 0; i < 3; i = i + 1) junk.push({ k: 100 + i });
	return xs[0].k * 100 + xs[1].k * 10 + xs[2].k;
}

export function main(): void {
	console.log("bang=" + fill(0) + " as=" + fill(1) + " bare=" + fill(2));
}

main();
