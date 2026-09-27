// @stdout: a|b|c|generic
// @exit: 0
// note: a module declares its own generic `trim<T>(this x: T)` while the prelude has `trim(this s: string)`. A call on a string inside that module, in a plain function or in the body of one of its generics, takes the prelude's exact receiver; the generic only serves receivers nothing else matches. The receiver counts as the call's first argument, so an exact receiver beats a generic one before the module's own scope is considered; it used to print `generic` for every call.

import { direct, inGeneric, onValue } from "./lib";

console.log(`${direct("  a  ")}|${inGeneric(1, " b ")}|${onValue(" c ")}|${onValue(5)}`);
