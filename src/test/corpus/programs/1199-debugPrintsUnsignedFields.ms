// @stdout: {"a":18446744073709551615,"b":4000000000,"c":200,"d":5}
// @stdout: {"big":9223372036854775809,"n":3}
class P { a: uint64 = 18446744073709551615; b: uint32 = 4000000000; c: uint8 = 200; d: uint64 = 5; }
struct S { big: uint64; n: uint8; }
console.log(`${new P()}`);
console.log(`${{ big: 9223372036854775809 as uint64, n: 3 as uint8 } as S}`);
