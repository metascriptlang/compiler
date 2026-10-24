class Cell {
	v: int32 = 1;
}

@exportName("guardHotLoop")
export function hotLoop(n: int32): int32 {
	const box = new Cell();
	const slots: Cell[] = [box, box, box, box];
	let sum = 0;
	for (let i = 0; i < n; i++) {
		slots[i % 4] = box;
		sum += slots[(i + 1) % 4].v;
	}
	return sum;
}

console.log(hotLoop(1000));
