// @columns: c, mixed
// @ledger-balanced: Counter
// @stdout: 8
// @stdout: destroyed 8
// @stdout: done
import { Handle } from "std/ffi";
import { open, bump } from "./handleDestroyWasm";

const a = open(5);
console.log(`${bump(a, 3)}`);
a.release();
console.log("done");
