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

let a = "";
for (const v of gen()) a = a + v.toString() + ",";
console.log(a);
let b = "";
for (const v of genString()) b = b + v + ",";
console.log(b);
console.log(await run());
