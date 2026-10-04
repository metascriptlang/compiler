// @stdout: 42 107 10 caller 3 24
// note: a macro's bindSym names a private function of the macro's own module, and the module that expands the macro calls it: directly, through a second macro, as a function value handed to an exported function, and from a generic body. The caller's own `dbl` stays its own. C emitted every private function `static`, so the expanding module's reference did not link.
import { twice, shifted, applyDbl } from "./lib";

function dbl(s: string): string { return "caller " + s; }

function viaGeneric<T>(v: T): number { return twice(12); }

console.log(`${twice(21)} ${shifted(7)} ${applyDbl(5)} ${dbl("3")} ${viaGeneric<string>("a")}`);
