let effects = 0;

function record(value: string): void {
	effects += value.length;
}

function expectEffects(expected: number): void {
	if (effects != expected) throw new Error(`effects=${effects}, expected=${expected}`);
}

function stopBeforeOperand(): void {
	const held = ["owned".repeat(8)];
	return
	record(held[0]);
}

function stopInsideComment(): void {
	const held = ["comment".repeat(8)];
	return /*
	*/ record(held[0]);
}

function sameLine(): void {
	return record("same");
}

function continuedOperand(): void {
	return (
		record("continued")
	);
}

for (let i = 0; i < 32; i += 1) {
	stopBeforeOperand();
	stopInsideComment();
}
console.log(`skipped=${effects}`);
expectEffects(0);
sameLine();
console.log(`same=${effects}`);
expectEffects(4);
continuedOperand();
console.log(`continued=${effects}`);
expectEffects(13);
