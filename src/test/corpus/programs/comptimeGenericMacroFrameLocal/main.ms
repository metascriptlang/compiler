// @stdout: a a|b b
// @exit: 0
// note: a generic routine whose body hands its parameter or a local to a macro is instantiated again for the compile-time VM by copying the checked body; the copy resolves those names to its own parameter and local. The copy used to keep the first instance's symbols and stopped with "'value' is a local of another function".

import { label, labelLocal } from "./helper";

interface Named { name: string; }
const n: Named = { name: "a" };
const direct = label(n) + " " + labelLocal(n);
const folded = @comptime {
	const m: Named = { name: "b" };
	return label(m) + " " + labelLocal(m);
};
console.log(direct + "|" + folded);
