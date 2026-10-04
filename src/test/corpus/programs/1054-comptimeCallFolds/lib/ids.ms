@comptime export function digitSum(text: string): uint64 {
	let total: uint64 = 0;
	for (let i = 0; i < text.length; i++) { total = total * 58 + ((text.charCodeAt(i) - 49) as uint64); }
	return total;
}

export struct Key {
	a: uint64;
	b: uint64;
}

@comptime export function keyOf(n: uint64): Key {
	return { a: n, b: n * 2 };
}

export enum Kind { Small, Large }

@comptime export function weight(kind: Kind, base: int32): int32 {
	return kind == Kind.Large ? base * 10 : base;
}

@comptime export function twice(n: int32): int32 {
	return n * 2;
}

@comptime export function sumOfTwice(n: int32): int32 {
	return twice(n) + twice(n + 1);
}

export const PROGRAM: uint64 = digitSum("2222");
