// @exit: 1
// @stdout: before the allocation
// @xfail(js): node attempts the allocation and reports its own RangeError trace on stderr, where C prints 'Error: value 70368744177664 not in range 0 .. 2147483647'
// @xfail(esm): node attempts the allocation and reports its own RangeError trace on stderr, where C prints 'Error: value 70368744177664 not in range 0 .. 2147483647'
// @xfail(raiser): error: Undefined variable 'Buffer'
// note: on C a Buffer length over the int32 bound is refused before the allocator is asked; node instead tries the allocation and throws its own RangeError. The allocator-failure path itself is pinned by src/test/guard/allocationFailureStopsUnderAddressLimit.ms; arrayLengthOverInt32IsRefused.ms covers arrays.

console.log("before the allocation");
const b = Buffer.alloc(70368744177664);
console.log(`buffer length ${b.length}`);
