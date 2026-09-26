// @xfail(raiser): the Raiser bytecode compiler cannot evaluate a class static field (symbol kind is Class), also on the baseline
// @stdout: 9007199254740993 18446744073709551615 -9007199254740993 -5 0.5 true
// note: a static field's integer initializer reaches C spelled from its exact value (codegen-c-11: int64 lost its last digit and uint64 max did not compile).

class K {
	static big: int64 = 9007199254740993;
	static top: uint64 = 18446744073709551615;
	static low: int64 = -9007199254740993;
	static neg: int32 = -5;
	static half: float64 = 0.5;
}
function run(): void {
	const local: int64 = 9007199254740993;
	console.log(K.big, K.top, K.low, K.neg, K.half, local == K.big);
}
run();
