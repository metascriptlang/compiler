// @stdout: 2080 552 28 496
// note: under a for whose bounds are integer literals and whose body does not write the counter, an index built from the counter and literals by + - * that stays inside a fixed array is read and written without a run-time check, and int32 arithmetic on it that stays inside int32 has no overflow check; the values are those of the checked form.

let w: int32[64] = [];

function fill(): void {
	for (let i = 0; i < 64; i++) w[i] = i + 1;
}

function sumAll(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 64; i++) t += w[i];
	return t;
}

function sumShifted(): int32 {
	let t: int32 = 0;
	for (let i = 16; i < 64; i++) t += w[i - 15] + w[i - 16] - w[i - 2];
	return t;
}

function sumGrid(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 8; i++) {
		for (let j = 0; j < 8; j++) {
			if (i == j) t += w[i * 8 + j] - w[i * 8];
		}
	}
	return t;
}

function sumStepped(): int32 {
	let t: int32 = 0;
	for (let i = 0; i < 64; i += 4) t += w[i];
	return t;
}

fill();
console.log(`${sumAll()} ${sumShifted()} ${sumGrid()} ${sumStepped()}`);
