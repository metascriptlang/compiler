// @stdout: 21.5 42 22.5
// note: modules that import each other read a function's inferred return type before its body is checked, one call deeper and from a method. Same output on C, JS and the Raiser.
import { half, Halver } from "./lib/half";

export function twice() { return base() * 2; }
function base() { return 21; }

console.log(`${half()} ${twice()} ${new Halver().plusOne()}`);
