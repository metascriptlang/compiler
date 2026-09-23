import { stdinHasData } from "std/io";

console.log(stdinHasData() ? "STDIN-IDLE-READY" : "STDIN-IDLE-EMPTY");
