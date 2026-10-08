// @exit: 1
// @stdout: before 3
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: `as T` out of a value-carried `T | null` holding null stops, inside a `try` too; it used to read "" (C, Raiser) or carry null on (JS).

function label(absent: boolean): string | null {
	if (absent) return null;
	return "abc";
}

console.log(`before ${(label(false) as string).length}`);
try {
	const text = label(true) as string;
	console.log(`after ${text.length}`);
} catch (e) {
	console.log("caught");
}
