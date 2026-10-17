// @stdout: b init: caught Cannot access 'fromA' before initialization
// @stdout: a sees: a1
// @stdout: main: a1
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: in an import cycle the module initialized first reads a const of the other module through a function before that module's declaration runs; it throws the ReferenceError JS throws instead of reading an empty string, and the later read sees the value.
import { fromA } from "./a";
console.log(`main: ${fromA}`);
