// @stdout: void slots ok
//
// A void call in an array element or object field has no value to store: it runs as
// its own statement and the slot keeps the null carrier. The hoist that makes this
// possible must not reorder evaluation, so effectful siblings ahead of the void slot
// move to temps — `trace` is the order witness (both backends share the transform, so
// byte-parity alone cannot judge this one).

let trace: string = "";

function tick(tag: string): void {
	trace = trace + tag;
}

function value(tag: string): int32 {
	trace = trace + tag;
	return 1;
}

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function main(): void {
	let ok = true;

	const a = [tick("a")];
	ok = check("arrayLen", a.length === 1) && ok;
	console.log("elem=" + a[0]);

	const b = [tick("b"), tick("c")];
	ok = check("arrayLen2", b.length === 2) && ok;

	const o = { v: tick("d") };
	console.log("field=" + o.v);

	// Mixed object: the valued field runs before the void one and keeps its value.
	const m = { a: value("e"), v: tick("f") };
	ok = check("mixedValue", m.a === 1) && ok;
	console.log("mixedVoid=" + m.v);

	ok = check("order", trace === "abcdef") && ok;

	if (!ok) { console.log("void slots FAILED trace=" + trace); return; }
	console.log("void slots ok");
}

main();
