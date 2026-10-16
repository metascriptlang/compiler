// @stdout: 42 41 abc 3 ready=yes
// note: exported functions read module bindings without a type annotation declared below them in their own module, a struct, a string, an array and a boolean, and another module calls them and reads the struct binding; every lane prints the initializers' values.
import { show, label, count, readied, LATER } from "./lib";

console.log(`${show()} ${LATER.n} ${label()} ${count()} ${readied()}`);
