// @ledger-slack(Box): 1
// @ledger-slack(Pair): 1
// @ledger-slack(int32_tArrayRefCell): 2
let trace = "";

function side(tag: string, v: int32): int32 {
	trace = trace + tag;
	return v;
}

async function val(tag: string, v: int32): Promise<int32> {
	trace = trace + tag;
	return v;
}

async function flag(tag: string, v: boolean): Promise<boolean> {
	trace = trace + tag;
	return v;
}

async function word(tag: string, s: string): Promise<string> {
	trace = trace + tag;
	return s;
}

function twice(n: int32): int32 {
	return n * 2;
}

function digits(a: int32, b: int32, c: int32): int32 {
	return a * 100 + b * 10 + c;
}

function report(name: string, v: string): void {
	console.log(`${name} v=${v} trace=${trace}`);
	trace = "";
}

class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

async function box(tag: string, n: int32): Promise<Box> {
	trace = trace + tag;
	return new Box(n);
}

class Pair {
	a: int32;
	b: int32;
	constructor(a: int32, b: int32) { this.a = a; this.b = b; }
}

struct Point { x: int32; y: int32; }

async function point(tag: string, y: int32): Promise<Point> {
	trace = trace + tag;
	return { x: 1, y };
}

async function nums(tag: string): Promise<int32[]> {
	trace = trace + tag;
	return [41, 42, 43];
}

function greet(tag: string): string {
	trace = trace + tag;
	return tag + "!";
}

async function spawnPlusOne(): Promise<int32> {
	const f1 = spawn(() => 41);
	return await f1 + 1;
}

async function twoAwaits(): Promise<int32> {
	return await val("g", 40) + await val("h", 2);
}

async function awaitAsArg(): Promise<int32> {
	return twice(await val("g", 21));
}

async function sideThenAwait(): Promise<int32> {
	return side("s", 1) + await val("g", 41);
}

async function andSkipsAwait(): Promise<boolean> {
	return false && await flag("g", true);
}

async function orSkipsAwait(): Promise<boolean> {
	return true || await flag("g", false);
}

async function ternarySkipsAwait(): Promise<int32> {
	return false ? await val("g", 1) : 7;
}

async function argsInOrder(): Promise<int32> {
	return digits(side("a", 1), await val("b", 2), side("c", 3));
}

async function assignAwait(): Promise<int32> {
	let x = 1;
	x = await val("g", 41) + x;
	return x;
}

async function ifCondAwait(): Promise<int32> {
	if (await val("g", 5) > 3) {
		return 1;
	}
	return 0;
}

async function whileCondAwait(): Promise<int32> {
	let i = 0;
	while (await val("w", i) < 3) {
		i = i + 1;
	}
	return i;
}

async function memberOfAwait(): Promise<int32> {
	return (await box("b", 42)).n;
}

async function concatAwait(): Promise<string> {
	return "<" + await word("w", "mid") + ">";
}

async function nestedAwait(): Promise<int32> {
	return await val("o", await val("i", 42));
}

async function notAwait(): Promise<boolean> {
	return !await flag("g", false);
}

const arrowSideThenAwait = async (): Promise<int32> => side("s", 1) + await val("g", 41);

async function elseIfAwait(): Promise<int32> {
	if (await val("a", 0) > 0) {
		return 1;
	} else if (await val("b", 2) > 1) {
		return 2;
	}
	return 3;
}

async function stmtAndAwait(): Promise<int32> {
	false && await flag("g", true);
	true && await flag("h", true);
	return 0;
}

async function compoundAssignAwait(): Promise<int32> {
	let x = 40;
	x += await val("g", 2);
	return x;
}

async function arrayInOrder(): Promise<string> {
	const arr = [side("a", 1), await val("b", 2), side("c", 3)];
	return `${arr[0]}${arr[1]}${arr[2]}`;
}

async function newInOrder(): Promise<int32> {
	const p = new Pair(side("a", 4), await val("b", 2));
	return p.a * 10 + p.b;
}

async function stringOperand(): Promise<string> {
	return greet("x") + await word("w", "mid");
}

async function structOfAwait(): Promise<int32> {
	return (await point("p", 42)).y;
}

async function indexOfAwait(): Promise<int32> {
	return (await nums("n"))[1];
}

report("async spawn-plus-one", `${await spawnPlusOne()}`);
report("async two-awaits", `${await twoAwaits()}`);
report("async await-as-arg", `${await awaitAsArg()}`);
report("async side-then-await", `${await sideThenAwait()}`);
report("async and-skips-await", `${await andSkipsAwait()}`);
report("async or-skips-await", `${await orSkipsAwait()}`);
report("async ternary-skips-await", `${await ternarySkipsAwait()}`);
report("async args-in-order", `${await argsInOrder()}`);
report("async assign-await", `${await assignAwait()}`);
report("async if-cond-await", `${await ifCondAwait()}`);
report("async while-cond-await", `${await whileCondAwait()}`);
report("async member-of-await", `${await memberOfAwait()}`);
report("async concat-await", await concatAwait());
report("async nested-await", `${await nestedAwait()}`);
report("async not-await", `${await notAwait()}`);
report("async arrow-side-then-await", `${await arrowSideThenAwait()}`);
report("async else-if-await", `${await elseIfAwait()}`);
report("async stmt-and-await", `${await stmtAndAwait()}`);
report("async compound-assign-await", `${await compoundAssignAwait()}`);
report("async array-in-order", await arrayInOrder());
report("async new-in-order", `${await newInOrder()}`);
report("async string-operand", await stringOperand());
report("async struct-of-await", `${await structOfAwait()}`);
report("async index-of-await", `${await indexOfAwait()}`);

const s1 = spawn(() => 41);
const syncSpawnPlusOne = await s1 + 1;
report("sync spawn-plus-one", `${syncSpawnPlusOne}`);
const syncTwoAwaits = await val("g", 40) + await val("h", 2);
report("sync two-awaits", `${syncTwoAwaits}`);
const syncAwaitAsArg = twice(await val("g", 21));
report("sync await-as-arg", `${syncAwaitAsArg}`);
const syncSideThenAwait = side("s", 1) + await val("g", 41);
report("sync side-then-await", `${syncSideThenAwait}`);
const syncAndSkipsAwait = false && await flag("g", true);
report("sync and-skips-await", `${syncAndSkipsAwait}`);
const syncOrSkipsAwait = true || await flag("g", false);
report("sync or-skips-await", `${syncOrSkipsAwait}`);
const syncTernarySkipsAwait = false ? await val("g", 1) : 7;
report("sync ternary-skips-await", `${syncTernarySkipsAwait}`);
const syncArgsInOrder = digits(side("a", 1), await val("b", 2), side("c", 3));
report("sync args-in-order", `${syncArgsInOrder}`);
let syncX = 1;
syncX = await val("g", 41) + syncX;
report("sync assign-await", `${syncX}`);
let syncIf = 0;
if (await val("g", 5) > 3) {
	syncIf = 1;
}
report("sync if-cond-await", `${syncIf}`);
let syncI = 0;
while (await val("w", syncI) < 3) {
	syncI = syncI + 1;
}
report("sync while-cond-await", `${syncI}`);
const syncMember = (await box("b", 42)).n;
report("sync member-of-await", `${syncMember}`);
const syncConcat = "<" + await word("w", "mid") + ">";
report("sync concat-await", syncConcat);
const syncNested = await val("o", await val("i", 42));
report("sync nested-await", `${syncNested}`);
const syncNot = !await flag("g", false);
report("sync not-await", `${syncNot}`);
let syncElseIf = 3;
if (await val("a", 0) > 0) {
	syncElseIf = 1;
} else if (await val("b", 2) > 1) {
	syncElseIf = 2;
}
report("sync else-if-await", `${syncElseIf}`);
false && await flag("g", true);
true && await flag("h", true);
report("sync stmt-and-await", "0");
let syncCompound = 40;
syncCompound += await val("g", 2);
report("sync compound-assign-await", `${syncCompound}`);
const syncArr = [side("a", 1), await val("b", 2), side("c", 3)];
report("sync array-in-order", `${syncArr[0]}${syncArr[1]}${syncArr[2]}`);
const syncPair = new Pair(side("a", 4), await val("b", 2));
report("sync new-in-order", `${syncPair.a * 10 + syncPair.b}`);
const syncString = greet("x") + await word("w", "mid");
report("sync string-operand", syncString);
const syncStruct = (await point("p", 42)).y;
report("sync struct-of-await", `${syncStruct}`);
const syncIndex = (await nums("n"))[1];
report("sync index-of-await", `${syncIndex}`);
