// @xfail(raiser): the Raiser VM shares one binding across sibling closures (prints '10,15,10,15,' where C prints '0,5,10,15,')
type StrThunk = () => string;
type IntThunk = () => int32;

function siblingBlocks(): string {
	const fs: StrThunk[] = [];
	{
		const x: string = "first";
		fs.push((): string => x);
	}
	{
		const x: string = "second";
		fs.push((): string => x);
	}
	return fs[0]() + "," + fs[1]();
}

function siblingIfBlocks(flag: boolean): string {
	let a: StrThunk | null = null;
	if (flag) {
		const x: string = "then";
		a = (): string => x;
	}
	if (true) {
		const x: string = "later";
		const b = (): string => x;
		b();
	}
	return a!();
}

function siblingTypes(): string {
	let out: string = "";
	{
		const x: string = "s";
		const f = (): string => x + "1";
		out = out + f();
	}
	{
		const x: int32 = 7;
		const g = (): int32 => x + 1;
		out = out + g().toString();
	}
	return out;
}

function siblingInLoopBody(): string {
	const fs: IntThunk[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		{
			const v: int32 = i * 10;
			fs.push((): int32 => v);
		}
		{
			const v: int32 = i * 10 + 5;
			fs.push((): int32 => v);
		}
	}
	let out = "";
	for (const f of fs) out = out + f().toString() + ",";
	return out;
}

function siblingInArrowFrame(): string {
	const run = (): string => {
		const fs: StrThunk[] = [];
		{
			const y: string = "left";
			fs.push((): string => y);
		}
		{
			const y: string = "right";
			fs.push((): string => y);
		}
		return fs[0]() + "," + fs[1]();
	};
	return run();
}

function expectStr(label: string, actual: string, expected: string): void {
	if (actual != expected) throw new Error(label + " expected=" + expected + " actual=" + actual);
}

const blocks = siblingBlocks();
const branches = siblingIfBlocks(true);
const types = siblingTypes();
const loop = siblingInLoopBody();
const arrow = siblingInArrowFrame();
expectStr("blocks", blocks, "first,second");
expectStr("branches", branches, "then");
expectStr("types", types, "s18");
expectStr("loop", loop, "0,5,10,15,");
expectStr("arrow", arrow, "left,right");
console.log(blocks);
console.log(branches);
console.log(types);
console.log(loop);
console.log(arrow);
