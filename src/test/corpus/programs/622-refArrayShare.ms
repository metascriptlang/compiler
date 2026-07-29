// @ledger-slack(msNumberArrayRefCell): 1
// @maxrss: 30
// @stdout: ref-array acc=13500000
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Ref<Array<T>> reference semantics (Phase 3 array migration): share-on-assign, mutate-through (direct/param/closure capture), length/index, string-element arrays. Refcounted box via msAllocTyped + per-element-type cell TypeInfo. Flat RSS proves the box frees its payload + the cell once.

// Reference-array (T[] = Ref<Array<T>>) semantics under DRC: share-on-assign,
// mutate-through (direct / via param / via closure capture), length, index,
// and string-element arrays — all reference-correct and leak-free across a
// hot loop. Each iteration's allocations must be freed (flat RSS).
// (Post-flip T[] IS the reference array; a bare `Ref<Array<T>>` annotation is a
// double-ref Ref<Ref<Array>> — use the T[] surface form the language exposes.)

function bump(a: number[]): void { a.push(7); }

function main(): void {
	let acc = 0;
	let i = 0;
	while (i < 500000) {
		const a: number[] = [1, 2, 3];
		const b = a;            // share — b aliases a's heap cell
		a.push(4);              // mutate through a → b sees it (len 4)
		bump(b);                // mutate through param → a sees it (len 5)
		const f = () => { a.push(9); };
		f();                    // closure capture mutate → len 6, a[5]=9
		const s: string[] = ["x", "y"];
		const t = s;
		s.push("z");            // string-element array, shared with t
		acc = acc + a.length + b.length + s.length + t.length + a[5];
		i = i + 1;
	}
	console.log("ref-array acc=" + acc.toString());
}

main();
