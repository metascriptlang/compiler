// @mixed-error: refusedAtCallbackWasm.ms:2:39
// @stdout: 2
// @stdout: a|b
import { each } from "./refusedAtCallbackWasm";

each(2, (rows: string[]): void => {
	console.log(`${rows.length}`);
	console.log(rows.join("|"));
});
