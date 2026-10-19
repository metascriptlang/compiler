// @stdout: before
// @exit: 0
// note: process.exit() with no code stops the program with status 0 on every backend, and nothing after it runs.

console.log("before");
process.exit();
console.log("never");
