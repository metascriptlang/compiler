// @stdout: hello|ffffffffffffffff|18446744073709551615|ff|-ff|zz|a,b|tagged 7|n=18446744073709551615 A|x18446744073709551615
// @stdout: 18446744073709551615 A
// note: a module's globals are destroyed when the program ends, not when that module's init returns.
// The importer and std's radix digits table read an exported string, an array and a struct after the
// exporting module's init ran; a destroy at the end of that init made them read empty and leaked one.
import { greeting, big, seeds, tag } from "./lib";

const k: int32 = 255;
const out: string[] = [
	greeting,
	big.toString(16),
	`${big}`,
	k.toString(16),
	(-k).toString(16),
	(1295).toString(36),
	seeds.join(","),
	`${tag.label} ${tag.n}`,
	`n=${big} ${65 as char}`,
];
let tail = "x";
tail += big;
out.push(tail);
console.log(out.join("|"));
console.log(big, 65 as char);
