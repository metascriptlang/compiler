// @stdout: a 1 hi
function present(x: string | null): NonNullable<string | null> {
	return x!;
}
function widen(x: NonNullable<int32 | null>): int32 {
	return x + 1;
}
function same(x: NonNullable<string>): string {
	return x;
}
console.log(present("a"), widen(0), same("hi"));
