// Parity program — the `defines` of the project's build.ms reach `define()` at compile time and
// `when` at parse, as `-d:` switches do: a string, a number, true, and false kept as the text "false".
//
// @stdout: id Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS|tier 2|fast|slow false
// @exit: 0

import { define } from "std/meta";

const id = @comptime { return define("programId"); };
const tier = @comptime { return define("tier"); };
const slow = @comptime { return define("slow"); };
let speed = "none";
when (fast) {
	speed = "fast";
}
console.log(`id ${id}|tier ${tier}|${speed}|slow ${slow}`);
