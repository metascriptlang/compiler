// @exit: 7
// @stdout: loop claimed
// @stdout: aborted foreign await
// @skip-js: binds the C fixture foreign.c, which awaits from a pthread the runtime did not create
// @skip-raiser: binds the C fixture foreign.c, whose pthread await has no Raiser host bridge
import { sleepAsync } from "std/core/promise";

@include("./foreign.h")
@compile("./foreign.c")
extern function msTestAwaitOnForeignThread(): int32;

await sleepAsync(1);
console.log("loop claimed");
console.log(`returned ${msTestAwaitOnForeignThread()}`);
