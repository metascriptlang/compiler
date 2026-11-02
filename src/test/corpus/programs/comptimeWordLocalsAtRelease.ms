// @stdout: 22 39 7 abc7
// note: a compile-time run whose frame holds plain integers (7, 15, 23, -1) ends with its heaps released; only reference slots are handles, so an integer whose low bits read as no heap kind is left alone instead of failing the compiler's range check.
function main(): void {
	const a = @comptime { const x: int64 = 7; const y: int64 = 15; return x + y; };
	const b = @comptime { const x: int64 = 23; const y: int64 = -1; const z: int64 = 15; return x + y + z + 2; };
	const c = @comptime { let n: int64 = 0; for (let i: int64 = 0; i < 7; i += 1) n += 1; return n; };
	const d = @comptime { const k: int64 = 7; return "abc" + k; };
	console.log(`${a} ${b} ${c} ${d}`);
}
main();
