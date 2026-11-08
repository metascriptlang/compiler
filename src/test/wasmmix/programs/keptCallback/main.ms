// @slots
// @stdout: got 1
// @stdout: got 2
// @stdout: last 7 after 70000 listens
// @stdout: once 3
// @stdout: done
import { listen, fire, forget } from "./keptCallbackWasm";

listen((n: int32): void => {
	console.log(`got ${n}`);
});
fire(1);
fire(2);

let last: int32 = -1;
for (let i = 0; i < 70000; i += 1) {
	listen((n: int32): void => {
		last = n;
	});
}
fire(7);
console.log(`last ${last} after 70000 listens`);

listen((n: int32): void => {
	console.log(`once ${n}`);
	forget();
});
fire(3);
fire(4);
console.log("done");
