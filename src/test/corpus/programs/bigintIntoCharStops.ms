// @exit: 1
// @stdout: value 300 not in range 0 .. 255
// @xfail(danger): --danger drops the range check, so C keeps the low byte instead of stopping
// @skip-raiser: the raiser has no bigint (BigIntLiteral is unsupported by its bytecode compiler)
// note: a bigint converted into char stops outside 0 .. 255 as an integer does; JS used to store 300 in the char.

function big(v: bigint): bigint { return v; }

console.log(`kept ${(big(0n) as char) as int32} ${(big(255n) as char) as int32}`);
console.log(`past ${(big(300n) as char) as int32}`);
console.log("unreachable");
