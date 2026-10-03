class AwaitOperandBox {
	v: int32 = 1;
	s: string = "a";
}

let awaitOperandX: int32 = 1;

let awaitOperandS: string = "s";

let awaitOperandI: int32 = 0;

let awaitOperandObj = new AwaitOperandBox();

const awaitOperandArr: int32[] = [10, 20, 30];

async function awaitOperandClobber(): Promise<int32> {
	awaitOperandX = 100;
	awaitOperandS = "S";
	awaitOperandI = 2;
	awaitOperandArr[0] = 99;
	awaitOperandObj = new AwaitOperandBox();
	awaitOperandObj.v = 50;
	awaitOperandObj.s = "z";
	return 5;
}

function awaitOperandPair(a: int32, b: int32): int32 {
	return a * 1000 + b;
}

async function awaitOperandReads(): Promise<string> {
	awaitOperandX = 1;
	const v = awaitOperandX + await awaitOperandClobber();
	awaitOperandObj = new AwaitOperandBox();
	const f = awaitOperandObj.v + await awaitOperandClobber();
	awaitOperandArr[0] = 10;
	const e = awaitOperandArr[0] + await awaitOperandClobber();
	awaitOperandX = 1;
	const a = awaitOperandPair(awaitOperandX, await awaitOperandClobber());
	awaitOperandS = "s";
	const s = awaitOperandS + (await awaitOperandClobber()).toString();
	awaitOperandX = 1;
	const after = (await awaitOperandClobber()) + awaitOperandX;
	return `${v} ${f} ${e} ${a} ${s} ${after}`;
}

async function awaitOperandStores(): Promise<string> {
	awaitOperandX = 1;
	awaitOperandX += await awaitOperandClobber();
	awaitOperandObj = new AwaitOperandBox();
	const first = awaitOperandObj;
	awaitOperandObj.v += await awaitOperandClobber();
	awaitOperandObj = new AwaitOperandBox();
	const second = awaitOperandObj;
	second.s = "a";
	awaitOperandObj.s += (await awaitOperandClobber()).toString();
	awaitOperandObj = new AwaitOperandBox();
	const third = awaitOperandObj;
	awaitOperandObj.v = await awaitOperandClobber();
	awaitOperandI = 0;
	awaitOperandArr[0] = 10;
	awaitOperandArr[2] = 30;
	awaitOperandArr[awaitOperandI] += await awaitOperandClobber();
	return `${awaitOperandX} ${first.v} ${second.s} ${third.v} ${awaitOperandArr[0]} ${awaitOperandArr[2]}`;
}

struct AwaitOperandPt {
	x: int32;
	y: int32;
}

async function awaitOperandValues(): Promise<string> {
	let p: AwaitOperandPt = { x: 5, y: 6 };
	p.x = await awaitOperandClobber();
	p.y += await awaitOperandClobber();
	const names: string[] = ["a"];
	names.push((await awaitOperandClobber()).toString());
	return `${p.x} ${p.y} ${names.join(",")}`;
}

class AwaitOperandCounter {
	v: int32 = 1;

	async bump(): Promise<int32> {
		this.v = 50;
		return 3;
	}

	async sum(): Promise<int32> {
		return this.v + await this.bump();
	}
}

async function awaitOperandComputed(): Promise<string> {
	awaitOperandX = 1;
	const sum = awaitOperandX + 1 + await awaitOperandClobber();
	awaitOperandX = 1;
	awaitOperandI = 0;
	awaitOperandArr[0] = 10;
	awaitOperandArr[1] = 20;
	awaitOperandArr[awaitOperandI + 1] = await awaitOperandClobber();
	awaitOperandX = 1;
	const pick = (awaitOperandX > 0 ? awaitOperandX : 0) + await awaitOperandClobber();
	awaitOperandX = 1;
	const neg = -awaitOperandX + await awaitOperandClobber();
	const own = await new AwaitOperandCounter().sum();
	return `${sum} ${awaitOperandArr[1]} ${pick} ${neg} ${own}`;
}

function awaitOperandWidePair(wide: int64, value: int32): string {
	return `${wide}+${value}`;
}

async function awaitOperandWidened(): Promise<string> {
	awaitOperandX = 1;
	const cast = (awaitOperandX as int64) + await awaitOperandClobber();
	awaitOperandX = 1;
	const argument = awaitOperandWidePair(awaitOperandX, await awaitOperandClobber());
	return `${cast} ${argument}`;
}

test "suspensionEvaluation: a read left of an await is read before it" {
	assert await awaitOperandReads() == "6 6 15 1005 s5 105";
}

test "suspensionEvaluation: a store whose value awaits reads and names its target before it" {
	assert await awaitOperandStores() == "100 6 a5 5 15 30";
}

test "suspensionEvaluation: a value struct and an array stay in place" {
	assert await awaitOperandValues() == "5 11 a,5";
}

test "suspensionEvaluation: computed operands, a computed index and a receiver's field are read before their awaits" {
	assert await awaitOperandComputed() == "7 5 6 4 4";
}

test "suspensionEvaluation: casts and implicit widening preserve the read before an await" {
	assert await awaitOperandWidened() == "6 1+5";
}

let operandTrace = "";
function traceOperand(tag: string, value: int32): int32 { operandTrace += tag; return value; }
async function awaitedOperand(tag: string, value: int32): Promise<int32> { operandTrace += tag; return value; }
async function awaitedFlag(tag: string, value: boolean): Promise<boolean> { operandTrace += tag; return value; }
function twiceOperand(value: int32): int32 { return value * 2; }
function takeOperandTrace(): string { const trace = operandTrace; operandTrace = ""; return trace; }
async function spawnedOperand(): Promise<int32> { const handle = spawn(() => 41); return await handle + 1; }
async function pairedOperands(): Promise<int32> { return await awaitedOperand("g", 40) + await awaitedOperand("h", 2); }
async function argumentOperand(): Promise<int32> { return twiceOperand(await awaitedOperand("g", 21)); }
async function orderedOperand(): Promise<int32> { return traceOperand("s", 1) + await awaitedOperand("g", 41); }
async function skippedAndOperand(): Promise<boolean> { return false && await awaitedFlag("g", true); }
async function skippedConditionalOperand(): Promise<int32> { return false ? await awaitedOperand("g", 1) : 7; }

test "suspensionEvaluation: async await operands preserve arithmetic arguments and evaluation order" {
	operandTrace = "";
	assert await spawnedOperand() == 42;
	assert await pairedOperands() == 42;
	assert takeOperandTrace() == "gh";
	assert await argumentOperand() == 42;
	assert takeOperandTrace() == "g";
	assert await orderedOperand() == 42;
	assert takeOperandTrace() == "sg";
}

test "suspensionEvaluation: async short-circuit branches never evaluate their suspended operands" {
	operandTrace = "";
	assert !await skippedAndOperand();
	assert takeOperandTrace() == "";
	assert await skippedConditionalOperand() == 7;
	assert takeOperandTrace() == "";
}

test "suspensionEvaluation: synchronous test consumers preserve await order and skipped branches" {
	operandTrace = "";
	const sum = traceOperand("s", 1) + await awaitedOperand("g", 41);
	assert sum == 42;
	assert takeOperandTrace() == "sg";
	const conjunction = false && await awaitedFlag("g", true);
	assert !conjunction;
	assert takeOperandTrace() == "";
	const conditional = false ? await awaitedOperand("g", 1) : 7;
	assert conditional == 7;
	assert takeOperandTrace() == "";
}
