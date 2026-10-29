// @stdout: second two a1 b0 t2
enum Flavor { First, Second }
type Kind = "a" | "b";
function byEnum(f: Flavor): string {
	switch (f) {
		case Flavor.First: return "first";
		case Flavor.Second: return "second";
	}
}
function byNumber(x: 1 | 2): string {
	switch (x) {
		case 1: return "one";
		case 2: return "two";
	}
}
function byFlag(b: boolean): string {
	switch (b) {
		case true: return "t";
		case false: return "f";
	}
}
function grouped(k: Kind, n: int32): string {
	switch (k) {
		case "a":
		case "b":
			return k + n;
	}
}
function mixed(k: Kind): string {
	switch (k) {
		case "a": return "a1";
		case "b": return "b0";
	}
}
console.log(byEnum(Flavor.Second), byNumber(2), mixed("a"), mixed("b"), byFlag(true) + grouped("a", 1).length);
