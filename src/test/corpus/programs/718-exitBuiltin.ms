// @stdout: exit-builtin before
// @exit: 3
console.log("exit-builtin before");
process.exit(3);
console.log("exit-builtin after");
