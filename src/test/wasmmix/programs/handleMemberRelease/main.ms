// @columns: c, mixed
// @ledger-balanced: Counter
// @stdout: visit 0
// @stdout: visit 1
// @stdout: visit 2
// @stdout: destroyed 3
// @stdout: sum 3
// @stdout: done
import { Handle } from "std/ffi";
import { Counter, open } from "./handleMemberReleaseWasm";

function visitAll(h: Handle<Counter>): int32 {
	return h.value().each((v: int32): void => {
		console.log(`visit ${v}`);
		if (v == 0) h.release();
	});
}

const sum = visitAll(open(3));
console.log(`sum ${sum}`);
console.log("done");
