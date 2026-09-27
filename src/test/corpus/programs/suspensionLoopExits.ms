// @stdout: suspension 3 6 12 100 42 5

async function breakAfterAwait(): Promise<int32> {
	let count: int32 = 0;
	while (true) {
		await sleepAsync(0);
		count += 1;
		if (count == 3) break;
	}
	return count;
}

async function take(values: int32[], stop: int32): Promise<int32> {
	let total: int32 = 0;
	for (const value of values) {
		if (value == stop) break;
		total += value;
	}
	return total;
}

async function skip(values: int32[], excluded: int32): Promise<int32> {
	let total: int32 = 0;
	let i: int32 = 0;
	while (i < values.length) {
		const value = values[i];
		i += 1;
		await sleepAsync(0);
		if (value == excluded) continue;
		total += value;
	}
	return total;
}

async function locate(matrix: int32[][], target: int32): Promise<int32> {
	let found: int32 = -1;
	let row: int32 = 0;
	while (row < matrix.length) {
		await sleepAsync(0);
		let column: int32 = 0;
		while (column < matrix[row].length) {
			if (matrix[row][column] == target) {
				found = row * 100 + column;
				break;
			}
			column += 1;
		}
		if (found >= 0) break;
		row += 1;
	}
	return found;
}

async function five(): Promise<int32> { return 5; }
export const exported = await five();
const typed = async (): Promise<int32> => 42;
const broken = await breakAfterAwait();
const taken = await take([1, 2, 3, 99, 4], 99);
const skipped = await skip([1, 2, 3, 4, 5], 3);
const position = await locate([[1, 2], [3, 4]], 3);
const value = await typed();
console.log(`suspension ${broken} ${taken} ${skipped} ${position} ${value} ${exported}`);
