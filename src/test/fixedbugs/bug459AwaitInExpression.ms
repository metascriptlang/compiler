// bug459 — an await inside an expression was not lowered on C
//
// Symptom:    on C, `const v = (await work(1)) + 1` printed 1 (the await and
//             its call vanished, leaving unary `+1`); an await as a call
//             argument, an assignment's right side, a condition, a template
//             part, an array element or a while condition emitted C that
//             did not compile. JS was correct.
// Root cause: src/transform/lowering/asyncDesugar.ms split out only
//             `return await p`; every other await in an operand reached the
//             state splitter as a yield it cannot place.
// Fix:        before await becomes yield, each await in an operand moves into
//             `const $awN = await p;` ahead of its statement, calls evaluated
//             before it are bound first so they still run first, `&&`, `||`
//             and `?:` become ifs so the await runs only on its branch, and a
//             loop condition moves into the loop body.
//
// Guarded end-to-end by corpus/programs/923-asyncAwaitExpressions.ms.

let b459Trace: string = "";

async function b459Work(x: int32): Promise<int32> {
	b459Trace = b459Trace + "w" + x.toString() + ";";
	return x * 2;
}

async function b459Flag(b: boolean): Promise<boolean> {
	b459Trace = b459Trace + "f;";
	return b;
}

function b459Note(tag: string, v: int32): int32 {
	b459Trace = b459Trace + tag + ";";
	return v;
}

async function b459Operands(): Promise<string> {
	const a = (await b459Work(1)) + 1;
	let b: int32 = 0;
	b = await b459Work(3);
	b += await b459Work(1);
	const c = `v=${await b459Work(2)}`;
	const d: int32[] = [await b459Work(1), 2];
	return `${a} ${b} ${c} ${d[0]} ${d[1]} ${Math.max(await b459Work(2), await b459Work(3))}`;
}

async function b459CallOrder(): Promise<int32> {
	return b459Note("h", 10) + (await b459Work(4)) + b459Note("k", 1);
}

async function b459ShortCircuit(): Promise<string> {
	const f1 = false && (await b459Flag(true));
	const f2 = true || (await b459Flag(false));
	const f3 = true && (await b459Flag(true));
	const g = f3 ? await b459Work(5) : await b459Work(6);
	return `${f1} ${f2} ${f3} ${g}`;
}

async function b459Conditions(): Promise<string> {
	let i: int32 = 0;
	while ((await b459Work(i)) < 6) { i++; }
	let out = i.toString();
	if (i > 100) {
		out = out + "no";
	} else if ((await b459Work(1)) == 2) {
		out = out + "elseif";
	}
	return out + (await b459Work(await b459Work(1))).toString();
}

async function b459DoWhile(): Promise<string> {
	let i: int32 = 0;
	let s = "";
	do {
		i++;
		if (i == 2) continue;
		s = s + i.toString();
	} while ((await b459Work(i)) < 8);
	return s;
}

test "bug459: an await in an operand, an assignment, a template and an array element" {
	assert await b459Operands() == "3 8 v=4 2 2 6";
}

test "bug459: a call left of an await runs before it" {
	b459Trace = "";
	assert await b459CallOrder() == 19;
	assert b459Trace == "h;w4;k;";
}

test "bug459: an await behind && || ?: runs only on its branch" {
	b459Trace = "";
	assert await b459ShortCircuit() == "false true true 10";
	assert b459Trace == "f;w5;";
}

test "bug459: an await in a while, else-if or nested await position" {
	assert await b459Conditions() == "3elseif4";
}

test "bug459: an await in a do-while condition runs after every pass, continue included" {
	assert await b459DoWhile() == "134";
}
