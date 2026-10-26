// @exit: 1
// @stdout: before the allocation
// note: a length over the int32 bound is refused before the allocator is asked, with the same message on every lane. The allocator-failure path itself is pinned by src/test/guard/allocationFailureStopsUnderAddressLimit.ms; bufferLengthOverInt32IsRefused.ms covers Buffer.

console.log("before the allocation");
const big = new Array<number>(8796093022208);
console.log(`array length ${big.length}`);
