// @stdout: true:lib 7 lib {"ok":true,"value":"lib"} 1:lib true
// note: a narrowed variant of a by-value union is a value and reaches an object parameter or array only as a written copy ('{ ...p }'); it stays itself as its union type, through a generic and through JSON.stringify. The refusal into an object is pinned in handoff/variantIntoObject.

type Pair = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
};

function mk(good: boolean): Pair {
	if (good) return { ok: true, value: "lib" };
	return { ok: false, error: "nope" };
}

function count(good: boolean): Result<int32, string> {
	if (good) return Result.ok(7);
	return Result.err("no");
}

function takeOk(x: { ok: true; value: string }): string {
	return `${x.ok}:${x.value}`;
}

function takeCount(x: { ok: true; value: int32 }): int32 {
	return x.value;
}

function takePair(x: Pair): boolean {
	return x.ok;
}

function same<T>(x: T): T {
	return x;
}

function main(): void {
	const p = mk(true);
	const r = count(true);
	const texts: { ok: true; value: string }[] = [];
	let arg = "";
	let num = 0;
	let through = "";
	let json = "";
	let taken = false;
	if (p.ok) {
		arg = takeOk({ ...p });
		texts.push({ ...p });
		through = same(p).value;
		json = JSON.stringify(p);
		taken = takePair(p);
	}
	if (r.ok) num = takeCount({ ...r });
	console.log(`${arg} ${num} ${through} ${json} ${texts.length}:${texts[0].value} ${taken}`);
}

main();
