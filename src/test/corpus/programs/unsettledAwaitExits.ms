// @stdout: before
// @exit: 13
// @skip-js: Node exits 13 here too, but its warning names the emitted .js file and quotes its source, so the output cannot be byte-compared with the native lanes
// note: a top-level await on a promise nothing can settle ends the program with exit 13 and a warning on stderr, as Node does, instead of waiting forever (the old C runtime hung; the old Raiser stopped with exit 1).

console.log("before");
await new Promise<void>((resolve) => {});
console.log("after");
