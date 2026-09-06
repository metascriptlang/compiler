// Language tests: control flow — if/else, while, for, for..of, break, continue

// ---- Shared helpers (outside test blocks) ----

enum Shape { Circle, Square, Triangle }

function classify(n: number): string {
	return match (n) {
		0 => "zero",
		1 => "one",
		2 | 3 => "small",
		_ => "big",
	};
}

function grade(score: number): string {
	return match (score) {
		5 => { const g = "A"; return g; },
		4 => { const g = "B"; return g; },
		3 => { const g = "C"; return g; },
		_ => { const g = "F"; return g; },
	};
}

function sides(s: Shape): number {
	return match (s) {
		Shape.Circle => 0,
		Shape.Square => 4,
		Shape.Triangle => 3,
		_ => -1,
	};
}

function findFirst(arr: number[], target: number): number {
	let idx = 0;
	while (idx < arr.length) {
		if (arr[idx] == target) return idx;
		idx += 1;
	}
	return -1;
}

function maxInArray(arr: number[]): number {
	if (arr.length == 0) return 0;
	let mx = arr[0];
	let i = 1;
	while (i < arr.length) {
		if (arr[i] > mx) mx = arr[i];
		i += 1;
	}
	return mx;
}

function minInArray(arr: number[]): number {
	if (arr.length == 0) return 0;
	let mn = arr[0];
	let i = 1;
	while (i < arr.length) {
		if (arr[i] < mn) mn = arr[i];
		i += 1;
	}
	return mn;
}

// ---- Match expressions ----

test "match expression with literals and alternatives" {
	assert classify(0) == "zero";
	assert classify(1) == "one";
	assert classify(2) == "small";
	assert classify(3) == "small";
	assert classify(99) == "big";
}

test "match expression with block arms" {
	assert grade(5) == "A";
	assert grade(4) == "B";
	assert grade(3) == "C";
	assert grade(0) == "F";
}

test "match expression with enum patterns" {
	assert sides(Shape.Circle) == 0;
	assert sides(Shape.Square) == 4;
	assert sides(Shape.Triangle) == 3;
}

// ---- C-style for loops ----

test "C-style for loop ascending" {
	let sum = 0;
	for (let i = 0; i < 5; i += 1) {
		sum += i;
	}
	assert sum == 10;
}

test "C-style for loop descending" {
	let sum = 0;
	for (let i = 10; i > 0; i -= 2) {
		sum += i;
	}
	assert sum == 30;
}

test "break in C-style for loop" {
	let firstBig = -1;
	const data: number[] = [1, 3, 5, 12, 7, 2];
	for (let i = 0; i < data.length; i += 1) {
		if (data[i] > 10) {
			firstBig = i;
			break;
		}
	}
	assert firstBig == 3;
}

test "for loop building arrays" {
	const squares: number[] = [];
	for (let i = 1; i <= 5; i += 1) {
		squares.push(i * i);
	}
	assert squares.length == 5;
	assert squares[0] == 1;
	assert squares[2] == 9;
	assert squares[4] == 25;
}

// ---- for..of loops ----

test "for..of summing numbers" {
	const nums: number[] = [10, 20, 30, 40, 50];
	let sum = 0;
	for (const n of nums) {
		sum += n;
	}
	assert sum == 150;
}

test "for..of concatenating strings" {
	const words: string[] = ["hello", " ", "world"];
	let joined = "";
	for (const w of words) {
		joined = joined + w;
	}
	assert joined == "hello world";
}

test "for..of counting with condition" {
	const items: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
	let evenCount = 0;
	for (const item of items) {
		if (item % 2 == 0) evenCount += 1;
	}
	assert evenCount == 5;
}

test "for..of with break" {
	const names: string[] = ["alice", "bob", "charlie", "diana"];
	let found = "";
	for (const name of names) {
		if (name.startsWith("c")) {
			found = name;
			break;
		}
	}
	assert found == "charlie";
}

// ---- while loops ----

test "while loop basic sum" {
	let count = 0;
	let sum = 0;
	while (count < 5) {
		sum += count;
		count += 1;
	}
	assert sum == 10;
}

test "while with break" {
	let count = 0;
	let i = 0;
	while (i < 100) {
		if (i == 7) break;
		count += 1;
		i += 1;
	}
	assert count == 7;
	assert i == 7;
}

test "while with continue skipping multiples of 3" {
	let skipSum = 0;
	let j = 0;
	while (j < 10) {
		j += 1;
		if (j % 3 == 0) continue;
		skipSum += j;
	}
	// 1+2+4+5+7+8+10 = 37
	assert skipSum == 37;
}

test "while with continue summing evens" {
	let evenSum = 0;
	let i = 0;
	while (i < 10) {
		i += 1;
		if (i % 2 != 0) continue;
		evenSum += i;
	}
	assert evenSum == 30;
}

test "while countdown to string" {
	let s = "";
	let n = 3;
	while (n > 0) {
		s = s + n;
		n -= 1;
	}
	assert s == "321";
}

// ---- do-while loops ----

test "do-while basic" {
	let count = 0;
	do {
		count += 1;
	} while (count < 3);
	assert count == 3;
}

test "do-while runs at least once" {
	let ranOnce = false;
	do {
		ranOnce = true;
	} while (false);
	assert ranOnce;
}

// ---- Nested control flow ----

test "nested while loops" {
	let cells = 0;
	let row = 0;
	while (row < 3) {
		let col = 0;
		while (col < 4) {
			cells += 1;
			col += 1;
		}
		row += 1;
	}
	assert cells == 12;
}

test "findFirst with while and early return" {
	const haystack: number[] = [5, 3, 8, 1, 9];
	assert findFirst(haystack, 8) == 2;
	assert findFirst(haystack, 1) == 3;
	assert findFirst(haystack, 99) == -1;
}

test "accumulator patterns" {
	assert maxInArray([3, 7, 2, 9, 1]) == 9;
	assert maxInArray([1]) == 1;
	assert maxInArray([5, 5, 5]) == 5;
	assert minInArray([3, 7, 2, 9, 1]) == 1;
}
