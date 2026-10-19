// @exit: 1
// @stdout: member 'bigint' is not accessible for type 'bigint | null' using 'null'
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: x! on a bigint | null that holds null ends the program with exit 1 and the same message as on a number | null, on C and JS; C used to stop in the transform with "cannot convert bigint | null to bigint".

function nb(v: bigint | null): bigint | null { return v; }

console.log("before");
const kept = nb(null)!;
console.log(`after ${kept}`);
