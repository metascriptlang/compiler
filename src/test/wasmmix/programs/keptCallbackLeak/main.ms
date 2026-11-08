// @columns: mixed
// @stdout: got 5
// @foreign-stdout: leaks tolerated: exit 0
// @foreign-stdout: MSB_LEAKS=error: exit 1
// @foreign-stdout: MSB_LEAKS=error keeps a program's own code: exit 3
// @mixed-stderr: msb leak: callback 'visit' kept by listen at keptCallbackLeakWasm.ms:4 never released
import { listen, fire } from "./keptCallbackLeakWasm";

listen((n: int32): void => {
	console.log(`got ${n}`);
});
fire(5);
