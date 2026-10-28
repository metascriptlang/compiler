// @stdout: 😀 4|Hé😀|empty|RangeError|RangeError|RangeError|RangeError|RangeError
// @exit: 0
// @skip-raiser: raiser strings are text, not bytes
function failure(cp: number): string {
	try {
		String.fromCodePoint(cp);
		return "none";
	} catch (e) {
		return e instanceof RangeError ? "RangeError" : "other";
	}
}
const emoji = String.fromCodePoint(0x1F600);
const parts: string[] = [
	`${emoji} ${emoji.byteLength}`,
	String.fromCodePoint(72, 233, 0x1F600),
	String.fromCodePoint().length == 0 ? "empty" : "not empty",
	failure(0x110000),
	failure(0xD800),
	failure(-1),
	failure(1.5),
	failure("x".parseFloat()),
];
console.log(parts.join("|"));
