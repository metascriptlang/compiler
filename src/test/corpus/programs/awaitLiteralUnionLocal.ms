// @stdout: const 5
// @stdout: annotated 5
// @stdout: passed 5
// @stdout: fraction 3
// @stdout: text aaab
// note: an await of a promise whose value is a literal union reads the value at the union's base type, whether it lands in an unannotated const, an annotated local or another async return, for integer, fractional and string literals.

type Step = 1 | 2;

async function step(big: boolean): Promise<Step> { return big ? 2 : 1; }
async function passed(big: boolean): Promise<Step> { return await step(big); }
async function half(big: boolean): Promise<0.5 | 1.5> { return big ? 1.5 : 0.5; }
async function letter(big: boolean): Promise<"a" | "b"> { return big ? "b" : "a"; }

async function sumConst(): Promise<int32> {
	let sum = 0;
	for (let i = 0; i < 4; i++) {
		const v = await step(i > 2);
		sum += v;
	}
	return sum;
}

async function sumAnnotated(): Promise<int32> {
	let sum = 0;
	for (let i = 0; i < 4; i++) {
		const v: Step = await step(i > 2);
		sum += v;
	}
	return sum;
}

async function sumPassed(): Promise<int32> {
	let sum = 0;
	for (let i = 0; i < 4; i++) sum += await passed(i > 2);
	return sum;
}

async function sumHalf(): Promise<number> {
	let sum = 0.0;
	for (let i = 0; i < 4; i++) {
		const v = await half(i > 2);
		sum += v;
	}
	return sum;
}

async function joined(): Promise<string> {
	let text = "";
	for (let i = 0; i < 4; i++) {
		const v = await letter(i > 2);
		text += v;
	}
	return text;
}

console.log("const", await sumConst());
console.log("annotated", await sumAnnotated());
console.log("passed", await sumPassed());
console.log("fraction", await sumHalf());
console.log("text", await joined());
