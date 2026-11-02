// @exit: 1
// @stdout: before the allocation
// note: a Buffer length over the int32 bound is refused before the allocator is asked, on C and on JS alike. The allocator-failure path itself is pinned by src/test/guard/allocationFailureStopsUnderAddressLimit.ms; arrayLengthOverInt32IsRefused.ms covers arrays.

console.log("before the allocation");
const b = Buffer.alloc(70368744177664);
console.log(`buffer length ${b.length}`);
