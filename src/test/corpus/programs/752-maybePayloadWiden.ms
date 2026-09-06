// @stdout: s:x n:7 null | s:ab n:1 null

// A nullable narrow type flowing into a nullable WIDER union is sound
// subtyping — `string | null` is a subset of `number | string | null` — but the
// two carriers have different C layouts: Maybe<string> holds its payload bare
// where Maybe<number|string> holds it in a tagged union. The bare direction
// already converted (widenVariantToUnion → HiddenSubConv + stamped slot); the
// nullable one had no arm and died at the reinterpret guard with "memory layout
// differs". Both call and assignment positions go through fitNode, so one arm
// covers both. The heap string is here so refcounting sees a real payload
// crossing into the union slot, not a literal.

function tail(): string { return "b"; }

function show(v: number | string | null): string {
	if (v == null) { return "null"; }
	if (typeof v == "string") { return "s:" + (v as string); }
	return "n:" + `${v as number}`;
}

export function main(): void {
	const s: string | null = "x";
	const n: number | null = 7;
	const z: string | null = null;
	let out = show(s) + " " + show(n) + " " + show(z);

	const h: string | null = "a" + tail();
	const m: number | null = 1;
	const hw: number | string | null = h;
	const mw: number | string | null = m;
	const zw: number | string | null = z;
	out = out + " | " + show(hw) + " " + show(mw) + " " + show(zw);

	console.log(out);
}

main();
