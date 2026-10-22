// @exit: 1
// @stdout: before the allocation
// @xfail(js): the JS runtime refuses the length with its own 'Error: over- or underflow' on stderr, where C prints 'Error: out of memory'
// @xfail(esm): the JS runtime refuses the length with its own 'Error: over- or underflow' on stderr, where C prints 'Error: out of memory'
// @xfail(raiser): the Raiser refuses the length with 'raiser runtime error: over- or underflow' on stderr, which the raiser cell keeps apart from the compared output
// @xfail(san): ASan refuses the request at its own maximum allocation size and aborts (exit 134) before the runtime's allocator sees a failure
// note: an array whose payload the allocator cannot provide stops the program at the allocation. It used to keep the requested length over a NULL payload and print "array length 8796093022208"; allocationFailureStopsBuffer.ms pins the buffer path.

console.log("before the allocation");
const big = new Array<number>(8796093022208);
console.log(`array length ${big.length}`);
