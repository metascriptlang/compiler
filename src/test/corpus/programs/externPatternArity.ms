// @stdout: 42 hi 3 | 1 #x | 7 [1,2,3]
when (js) {
	extern class Box { size: int32; }
	extern function answer(): int32 from "(40 + 2)";
	extern function greeting(): string from "('h' + 'i')";
	extern function makeBox(): Box from "({ size: 3 })";
	extern function hashAt(s: string): int32 from "(#).indexOf('\\x23')";
	extern function tagged(s: string): string from "('\\x23' + #)";
	extern function sum(a: int32, b: int32): int32 from "(# + #)";
	extern function listed(first: int32, second: int32, third: int32): string from "JSON.stringify([#, @])";
} else {
	interface Box { size: int32; }
	function answer(): int32 { return 42; }
	function greeting(): string { return "hi"; }
	function makeBox(): Box { return { size: 3 }; }
	function hashAt(s: string): int32 { return s.indexOf("#"); }
	function tagged(s: string): string { return "#" + s; }
	function sum(a: int32, b: int32): int32 { return a + b; }
	function listed(first: int32, second: int32, third: int32): string { return `[${first},${second},${third}]`; }
}

console.log(`${answer()} ${greeting()} ${makeBox().size} | ${hashAt("a#b")} ${tagged("x")} | ${sum(3, 4)} ${listed(1, 2, 3)}`);
