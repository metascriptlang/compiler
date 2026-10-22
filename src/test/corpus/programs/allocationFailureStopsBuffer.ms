// @exit: 1
// @stdout: before the allocation
// @xfail(js): node reports its failed ArrayBuffer allocation with its own RangeError trace on stderr, where C prints 'Error: out of memory'
// @xfail(esm): node reports its failed ArrayBuffer allocation with its own RangeError trace on stderr, where C prints 'Error: out of memory'
// @xfail(raiser): error: Undefined variable 'Buffer'
// @xfail(san): ASan refuses the request at its own maximum allocation size and aborts (exit 134) before the runtime's allocator sees a failure
// note: a buffer the allocator cannot provide stops the program at the allocation. It used to come back empty and print "buffer length 0"; allocationFailureStopsArray.ms pins the array path.

console.log("before the allocation");
const b = Buffer.alloc(70368744177664);
console.log(`buffer length ${b.length}`);
