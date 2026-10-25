// @stdout: private 1 2 3 4|alias 10 40|namespace 20 30
// note: two modules each declare an enum of one name; every member keeps the value its own
// declaration gives it, read inside the module, through an import alias or a namespace import.
// The JS bundle used to emit both member sets under one name, so the later module's won.
import { a, xb, Level as XLevel } from "./x";
import { b, yb, Level as YLevel } from "./y";
import * as X from "./x";
import * as Y from "./y";

function num(n: number): number { return n; }

console.log(`private ${a()} ${b()} ${xb()} ${yb()}|alias ${num(XLevel.Low)} ${num(YLevel.High)}|namespace ${num(X.Level.High)} ${num(Y.Level.Low)}`);
