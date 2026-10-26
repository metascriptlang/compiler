function makeScaler(k: number): (x: number) => number {
	return (x: number): number => x * k;
}

const source: number[] = [];
for (let i = 0; i < 20000; i += 1) source.push(i);
let total: number = 0;
for (let round = 0; round < 50; round += 1) {
	const scale = makeScaler(round + 2);
	const out = source.map(scale).filter((x: number): boolean => x % 3 == 0).map((x: number): number => x + round);
	total += out.length + out[out.length - 1];
}
console.log(`closures ${total}`);
