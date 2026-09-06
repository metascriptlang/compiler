// @stdout: vec-refarray-span-legal done

// The legal surface around the Vec<T> ↔ T[] container-kind ban (guard
// vecRefArrayDistinct): contextual literals type straight into either
// container, and BOTH feed Span<T> — the Ref peel into the Span coercion arm
// must survive the auto-deref tightening (target Span, not Array).

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function takeSpan(s: Span<int32>): int32 { return s.length; }

function literalBoth(): boolean {
	const r: int32[] = [1, 2];
	const v: Vec<int32> = [1, 2, 3];
	return r.length == 2 && v.length == 3;
}

function refArrayToSpan(): boolean {
	const r: int32[] = [1, 2];
	const s: Span<int32> = r;
	return takeSpan(r) == 2 && s.length == 2;
}

function vecToSpan(): boolean {
	const v: Vec<int32> = [1, 2, 3];
	const s: Span<int32> = v;
	return takeSpan(v) == 3 && s.length == 3;
}

function main(): void {
	let ok = true;
	ok = check("literalBoth", literalBoth()) && ok;
	ok = check("refArrayToSpan", refArrayToSpan()) && ok;
	ok = check("vecToSpan", vecToSpan()) && ok;
	if (ok) { console.log("vec-refarray-span-legal done"); }
}

main();
