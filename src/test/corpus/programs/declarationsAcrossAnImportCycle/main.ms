// @stdout: Ab 7 2 ab3 c4:10
// note: two modules that import each other. The module checked first reads the other's const and let written without a type, constructs its class, and calls a function and a method whose return types are inferred; that function reads back a function of the first module declared below its caller. Every lane prints the values.
import { useB, viaB } from "./a";
import { half, label, counted } from "./b";

console.log(`${useB()} ${viaB()} ${half()} ${label()} ${counted()}`);
