// @mixed-error: keeps its callback parameter 'visit'
// @columns: mixed
// @stdout: done
import { listen } from "./refusedKeptCallbackWasm";

listen((n: int32): void => {
	console.log(`${n}`);
});
console.log("done");
