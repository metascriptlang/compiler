// @columns: c, mixed
// @stdout: 7
// @stdout: guard 7 released
// @stdout: cleared
// @stdout: 9
// @stdout: owner 9 released
// @stdout: 3
// @stdout: guard 3 released
// @stdout: done
import { keepGuard, keepOwner, callKept, clearKept } from "./closureEnvDestroyWasm";

keepGuard(7);
console.log(`${callKept()}`);
clearKept();
console.log("cleared");
keepOwner(9);
console.log(`${callKept()}`);
keepGuard(3);
console.log(`${callKept()}`);
clearKept();
console.log("done");
