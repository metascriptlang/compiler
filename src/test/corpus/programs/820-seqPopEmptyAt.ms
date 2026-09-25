struct Pair { name: string; n: int64; }

function popEmptyInt32(): void {
	const a: int32[] = [1];
	a.pop();
	const x = a.pop();
	console.log(`int32 pop-empty ${x > 0 ? "value" : "none"} len=${a.length}`);
	for (let i: int32 = 7; i < 13; i++) { a.push(i); }
	console.log(`int32 after-push len=${a.length} first=${a[0]}`);
}

function popEmptyStruct(): void {
	const a: Pair[] = [];
	a.pop();
	a.pop();
	for (let i: int32 = 0; i < 5; i++) {
		const p: Pair = { name: "p".repeat(i + 1), n: i as int64 };
		a.push(p);
	}
	console.log(`struct after-push len=${a.length} first=${a[0].name} last=${a[4].name}`);
}

function atOutOfRange(): void {
	const a: int32[] = [1, 2, 3];
	a.push(4);
	a.pop();
	console.log(`at in-range ${a.at(0)} ${a.at(-1)}`);
	console.log(`at past-end ${(a.at(3) as number) > 0 ? "stale" : "clear"}`);
	console.log(`at before-start ${(a.at(-5) as number) > 0 ? "stale" : "clear"}`);
	const b: int64[] = [5, 6];
	b.push(7 as int64);
	b.pop();
	console.log(`int64 at past-end ${(b.at(2) as number) > 0 ? "stale" : "clear"}`);
}

popEmptyInt32();
popEmptyStruct();
atOutOfRange();
