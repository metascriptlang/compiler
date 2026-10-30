// @stdout: set|set|null
import { holdNull, emptyCell } from "./box";
import { Kind } from "./kinds";
console.log([holdNull(Kind.Offline), holdNull("s"), emptyCell(Kind.Online)].join("|"));
