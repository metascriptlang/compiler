// @exit: 1
// @stdout: before the allocation
// @xfail(raiser): the Raiser refuses the length with 'raiser runtime error: over- or underflow' on stderr, which the raiser cell keeps apart from the compared output
// note: a length over the int32 bound is refused before the allocator is asked, with the same message on every lane. The allocator-failure path itself is pinned by src/test/guard/allocationFailureStopsUnderAddressLimit.ms; bufferLengthOverInt32IsRefused.ms covers Buffer.

console.log("before the allocation");
const big = new Array<number>(8796093022208);
console.log(`array length ${big.length}`);
