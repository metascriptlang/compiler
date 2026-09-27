// @xfail(raiser): the Raiser VM cannot compile a yield expression ('cannot compile node kind YieldExpr')
function* gen(): Iterator<int32> {
	let i: int32 = 0;
	while (i < 4) {
		switch (i) {
			default:
				yield i * 10;
				switch (i) {
					case 1:
						if (i > 0) break;
						yield 99;
						break;
					default:
						i += 0;
				}
				if (i == 1) break;
				yield i;
		}
		i++;
	}
}

function* genString(): Iterator<string> {
	const names: string[] = ["a", "skip", "c"];
	let i: int32 = 0;
	while (i < 3) {
		const n = names[i];
		switch (n) {
			case "skip":
				yield "s";
				if (i > 0) break;
				yield "never";
				break;
			default:
				yield n;
		}
		i++;
	}
}

async function tick(x: int32): Promise<int32> {
	return x;
}

async function run(): Promise<string> {
	let out = "";
	let i: int32 = 0;
	while (i < 4) {
		switch (i) {
			default:
				const v = await tick(i);
				if (v == 1) break;
				out = out + v.toString();
		}
		i++;
	}
	return out;
}

function expectStr(label: string, actual: string, expected: string): void {
	if (actual != expected) throw new Error(label + " expected=" + expected + " actual=" + actual);
}

let a = "";
for (const v of gen()) a = a + v.toString() + ",";
expectStr("gen", a, "0,0,10,20,2,30,3,");
console.log(a);
let b = "";
for (const v of genString()) b = b + v + ",";
expectStr("genString", b, "a,s,c,");
console.log(b);
const asyncValues = await run();
expectStr("run", asyncValues, "023");
console.log(asyncValues);
