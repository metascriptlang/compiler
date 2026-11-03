// @stdout: sum 21 | skip 12 | stop 6 | nested 441 | grow raised after 3: the length of the array changed while iterating over it | shrink raised after 1: the length of the array changed while iterating over it

function sum(xs: int32[]): int64 {
	let total: int64 = 0;
	for (const x of xs) total += x as int64;
	return total;
}

function skipOdd(xs: int32[]): int64 {
	let total: int64 = 0;
	for (const x of xs) {
		if (x % 2 == 1) continue;
		total += x as int64;
	}
	return total;
}

function stopAt(xs: int32[], limit: int32): int64 {
	let total: int64 = 0;
	for (const x of xs) {
		if (x > limit) break;
		total += x as int64;
	}
	return total;
}

function nested(xs: int32[]): int64 {
	let total: int64 = 0;
	for (const a of xs) {
		for (const b of xs) total += (a * b) as int64;
	}
	return total;
}

function grow(xs: int32[]): string {
	let seen = 0;
	try {
		for (const x of xs) { seen += 1; if (x == 3) xs.push(x + 10); }
	} catch (e) {
		return "grow raised after " + String(seen) + ": " + e.message;
	}
	return "grow finished";
}

function shrink(xs: int32[]): string {
	let seen = 0;
	try {
		for (const x of xs) { seen += 1; xs.pop(); }
	} catch (e) {
		return "shrink raised after " + String(seen) + ": " + e.message;
	}
	return "shrink finished";
}

const six: int32[] = [1, 2, 3, 4, 5, 6];
console.log(
	"sum " + String(sum(six)) + " | skip " + String(skipOdd(six)) + " | stop " + String(stopAt(six, 3)) +
	" | nested " + String(nested(six)) + " | " + grow([1, 2, 3]) + " | " + shrink([5, 6, 7])
);
