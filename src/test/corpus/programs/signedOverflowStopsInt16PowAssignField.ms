// @exit: 1
// @stdout: kept 32761
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the power wraps in C instead of stopping
// @skip-raiser: the raiser stops too, with a range error on stderr, which the raiser lane does not read; run it with msc run --target=raiser
// note: `**=` on an int16 field stops when the power leaves int16 but still fits int32, where it wrapped to -25536 on C before.

class Box {
	v: int16 = 0;
}

function int16Of(n: int32): int16 { return n as int16; }

const b = new Box();
b.v = int16Of(181);
b.v **= int16Of(2);
console.log(`kept ${b.v}`);
b.v = int16Of(200);
b.v **= int16Of(2);
console.log(`unreachable ${b.v}`);
