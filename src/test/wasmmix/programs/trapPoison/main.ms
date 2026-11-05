// @columns: mixed
// @stdout: 7
// @foreign-stdout: runtime trap: true
// @foreign-stdout: blocked: true
// @foreign-stdout: cause: true
import { ping } from "./trapPoisonWasm";
export { ping, trapNow } from "./trapPoisonWasm";
console.log(ping());
