// @stdout: generic:1 1 1|plain:true true true false|nested:true true|async:3|call:S,true
// note: a value a closure captured compares with `null` as it does outside the closure: a `P | null` parameter of a generic class method keeps its runtime answer for a string, an integer and a class instance, and a string, a struct and an array that are never null fold to the constant, one and two closures deep and after an `await`. An operand with a call inside the closure still runs once. Same output on every backend.

struct Pt { x: int32; }
class Box { v: int32 = 1; }

class Nav<P> {
	seen: int32 = 0;
	run(f: () => void): void { f(); }
	go(params: P | null): void {
		this.run((): void => {
			if (params !== null) { this.seen += 1; }
		});
	}
}

function run(f: () => void): void { f(); }

function genericAnswers(): string {
	const s = new Nav<string>();
	s.go("x");
	s.go(null);
	const i = new Nav<int32>();
	i.go(3);
	i.go(null);
	const b = new Nav<Box>();
	b.go(new Box());
	b.go(null);
	return `${s.seen} ${i.seen} ${b.seen}`;
}

function plainAnswers(s: string, p: Pt, xs: int32[]): string {
	let out = "";
	run((): void => {
		const isS = s !== null;
		const isP = p != null;
		const isXs = null !== xs;
		const noS = s === null;
		out = `${isS} ${isP} ${isXs} ${noS}`;
	});
	return out;
}

function nestedAnswers(s: string): string {
	let out = "";
	run((): void => {
		const t: string = s + "t";
		run((): void => {
			const isS = s !== null;
			const isT = t != null;
			out = `${isS} ${isT}`;
		});
	});
	return out;
}

async function tick(): Promise<int32> { return 2; }

async function afterAwait(s: string): Promise<int32> {
	const t = await tick();
	if (s !== null) { return t + 1; }
	return t;
}

let trace = "";
function makeS(): string {
	trace = trace + "S,";
	return "s";
}

function callAnswer(label: string): string {
	let out = "";
	run((): void => {
		const isS = makeS() !== null;
		out = `${label}${trace}${isS}`;
	});
	return out;
}

async function main(): Promise<void> {
	const generic = genericAnswers();
	const plain = plainAnswers("a", { x: 1 }, [1, 2]);
	const nested = nestedAnswers("a");
	const awaited = await afterAwait("a");
	const call = callAnswer("call:");
	console.log(`generic:${generic}|plain:${plain}|nested:${nested}|async:${awaited}|${call}`);
}
main();
