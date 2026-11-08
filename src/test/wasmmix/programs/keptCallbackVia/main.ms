// @slots
// @stdout: a 1
// @stdout: b 1
// @stdout: owned 101
// @stdout: 2
// @stdout: 0
// @stdout: last 103 after 70000 adopts
// @stdout: done
import { listen, adopt, fire, clear } from "./keptCallbackViaWasm";

listen((n: int32): void => {
	console.log(`a ${n}`);
});
listen((n: int32): void => {
	console.log(`b ${n}`);
});
adopt((n: int32): void => {
	console.log(`owned ${n}`);
});
console.log(`${fire(1)}`);
clear();
console.log(`${fire(2)}`);

let last: int32 = -1;
for (let i = 0; i < 70000; i += 1) {
	adopt((n: int32): void => {
		last = n;
	});
}
fire(3);
console.log(`last ${last} after 70000 adopts`);
clear();
console.log("done");
