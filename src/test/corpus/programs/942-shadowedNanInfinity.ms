// @xfail(raiser): the Raiser bytecode compiler cannot evaluate the builtin NaN / Infinity (symbol has no declaration node), also on the baseline
// @stdout: 6 42 true true
// note: a parameter or local named NaN / Infinity is its own symbol; only the builtins are the C macros (codegen-c-12: C matched the name).

function scale(Infinity: int32): int32 { return Infinity * 2; }
function shadow(): int32 {
	const NaN: int32 = 5;
	return NaN + 1;
}
const nan = NaN;
console.log(`${shadow()} ${scale(21)} ${nan != nan} ${Infinity > 1e308}`);
