// @stdout: true:lib 7 true:lib true:lib 1:lib 1:7 true
// note: a union variant that a guard narrowed reaches a parameter, a typed local or an array element written as the same object type, as the reference TypeScript relates a narrowed constituent to a structurally identical object type. The variant is rebuilt as that object member-wise, so the callee holds a copy (a write through the parameter does not reach the union). Covered for an inline match union and for Result, a discriminant written boolean in the parameter, and a written object passed where the match type is expected.

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

function takeWide(x: { ok: boolean; value: string }): string {
	return `${x.ok}:${x.value}`;
}

function takePair(x: Pair): boolean {
	return x.ok;
}

function main(): void {
	const p = mk(true);
	const r = count(true);
	const texts: { ok: true; value: string }[] = [];
	const counts: { ok: true; value: int32 }[] = [];
	let arg = "";
	let num = 0;
	let wide = "";
	let local = "";
	if (p.ok) {
		arg = takeOk(p);
		wide = takeWide(p);
		const q: { ok: true; value: string } = p;
		local = `${q.ok}:${q.value}`;
		texts.push(p);
	}
	if (r.ok) {
		num = takeCount(r);
		counts.push(r);
	}
	const written: { ok: true; value: string } = { ok: true, value: "w" };
	console.log(`${arg} ${num} ${wide} ${local} ${texts.length}:${texts[0].value} ${counts.length}:${counts[0].value} ${takePair(written)}`);
}

main();
