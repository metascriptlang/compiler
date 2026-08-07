// note: two aliases of DIFFERENT anonymous object types through ONE generic —
// the instantiation cache keys on monoTypeKey, which returned "" for every
// anonymous struct, so the second call reused the first's body (guard bug090).
type Named = { name: string };
type Tagged = { tag: string };
type Pair = { lo: int32, hi: int32 };

function wrapOne<T>(v: T): Result<T, string> { return Result.ok(v); }

function firstOf<T>(items: T[]): T { return items[0]; }

function main(): void {
	const a = wrapOne<Named>({ name: "n1" });
	const b = wrapOne<Tagged>({ tag: "t2" });
	if (a.ok) { console.log(a.value.name); }
	if (b.ok) { console.log(b.value.tag); }

	const c = wrapOne<Pair>({ lo: 3, hi: 9 });
	if (c.ok) { console.log(c.value.lo + c.value.hi); }

	const named: Named[] = [{ name: "x" }, { name: "y" }];
	const tagged: Tagged[] = [{ tag: "p" }, { tag: "q" }];
	console.log(firstOf<Named>(named).name);
	console.log(firstOf<Tagged>(tagged).tag);

	let i = 0;
	while (i < 3) {
		const r = wrapOne<Named>({ name: "loop" + i.toString() });
		if (r.ok) { console.log(r.value.name); }
		i = i + 1;
	}
}
main();
