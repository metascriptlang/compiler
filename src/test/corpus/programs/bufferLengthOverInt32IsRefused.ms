// @stdout: before the allocation
// @stdout: The value of "size" is out of range. It must be >= 0 && <= 2147483647. Received 70_368_744_177_664
// note: a Buffer length over the int32 bound (Buffer's kMaxLength) is a RangeError before the allocator is asked, on C and on JS alike. The allocator-failure path itself is pinned by src/test/guard/allocationFailureStopsUnderAddressLimit.ms; arrayLengthOverInt32IsRefused.ms covers arrays.

console.log("before the allocation");
try {
	const b = Buffer.alloc(70368744177664);
	console.log(`buffer length ${b.length}`);
} catch (e) {
	console.log((e as Error).message);
}
