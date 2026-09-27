// @xfail(raiser): the Raiser VM stops with 'expected an object, got value kind Int' in an await expression
let trace = "";

async function work(x: int32): Promise<int32> {
	trace = trace + "w" + x.toString() + ";";
	return x * 2;
}

async function flag(b: boolean): Promise<boolean> {
	trace = trace + "f;";
	return b;
}

function note(tag: string, v: int32): int32 {
	trace = trace + tag + ";";
	return v;
}

class Box {
	items: int32[] = [];
	add(v: int32): void { this.items.push(v); }
}

function mkBox(tag: string): Box {
	trace = trace + tag + ";";
	return new Box();
}

async function sum(n: int32): Promise<int32> {
	return (await work(n)) + (await work(n + 1));
}

async function pick(c: boolean): Promise<string> {
	return c ? "yes" + (await work(1)).toString() : "no";
}

async function operands(): Promise<void> {
	const a = (await work(1)) + 1;
	let b: int32 = 0;
	b = await work(3);
	b += await work(1);
	const c = `v=${await work(2)}`;
	const d: int32[] = [await work(1), note("n", 2)];
	const s: string = "k" + (await work(21)).toString();
	assert a == 3 && b == 8 && c == "v=4";
	assert d[0] == 2 && d[1] == 2 && s == "k42";
	console.log(`${a} ${b} ${c} ${d[0]} ${d[1]} ${s}`);
	const maximum = Math.max(await work(2), await work(3));
	assert maximum == 6;
	console.log(maximum);
	const nested = await work(await work(1));
	assert nested == 4;
	console.log(nested);
	console.log(trace);
}

async function order(): Promise<void> {
	trace = "";
	const e = note("h", 10) + (await work(4)) + note("k", 1);
	assert e == 19 && trace == "h;w4;k;";
	console.log(`${e} ${trace}`);
	trace = "";
	const box = mkBox("m1");
	box.add(await work(7));
	mkBox("m2").add(await work(8));
	assert box.items[0] == 14 && trace == "m1;w7;m2;w8;";
	console.log(`${box.items[0]} ${trace}`);
}

async function branches(): Promise<void> {
	trace = "";
	const f1 = false && (await flag(true));
	const f2 = true || (await flag(false));
	const f3 = true && (await flag(true));
	const f4 = false || (await flag(false));
	const g = f3 ? await work(5) : await work(6);
	assert !f1 && f2 && f3 && !f4 && g == 10;
	assert trace == "f;f;w5;";
	console.log(`${f1} ${f2} ${f3} ${f4} ${g} ${trace}`);
	const yes = await pick(true);
	assert yes == "yes2";
	console.log(yes);
	const no = await pick(false);
	assert no == "no";
	console.log(no);
	const total = await sum(1);
	assert total == 6;
	console.log(total);
}

async function loops(): Promise<void> {
	let i: int32 = 0;
	while ((await work(i)) < 6) { i++; }
	assert i == 3;
	console.log(i);
	if (i > 100) {
		console.log("no");
	} else if ((await work(1)) == 2) {
		console.log("elseif");
	}
	let j: int32 = 0;
	let s = "";
	do {
		j++;
		if (j == 2) continue;
		s = s + j.toString();
	} while ((await work(j)) < 8);
	assert s == "134";
	console.log(s);
}

async function main(): Promise<void> {
	await operands();
	await order();
	await branches();
	await loops();
}

await main();
