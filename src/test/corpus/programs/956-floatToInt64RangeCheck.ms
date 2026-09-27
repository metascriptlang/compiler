// @exit: 1
// @stdout: start 3 -3 9007199254740992 -9223372036854775808
// @xfail(danger): --danger elides the range check, so the out-of-range conversion is undefined there
// @xfail(js): float to integer conversions are not range-checked on JS yet (NIM-REF CG-3); JS prints the value past int64
// @xfail(raiser): Raiser converts a float past int64 without a range check and prints -9223372036854775808 (same on the baseline)
// @xfail(esm): float to integer conversions are not range-checked on JS yet (NIM-REF CG-3); ESM prints the value past int64
// note: a float converted to int64 is checked against the int64 range on the double before the cast, NaN and 1e19 included (codegen-c-13, stmt-lowering-19: the conversion had no check and printed garbage under --release).

function toI64(f: number): int64 { return f as int64; }

console.log(`start ${toI64(3.9)} ${toI64(-3.9)} ${toI64(9007199254740992.0)} ${toI64(-9223372036854775808.0)}`);
console.log(toI64(1e19));
console.log("after");
