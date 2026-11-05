// @columns: mixed
// @stdout: 7
// @foreign-stdout: vec threw: true
// @foreign-stdout: vec blocked: true
// @foreign-stdout: vec cause: true
// @foreign-stdout: 7
// @foreign-stdout: text threw: true
// @foreign-stdout: text blocked: true
// @foreign-stdout: text cause: true
export { numbers, text, ping } from "./resultThrowPoisonWasm";
import { ping } from "./resultThrowPoisonWasm";

console.log(ping());
