// @xfail(raiser): the Raiser VM holds an enum as its ordinal: the by-name text of one reached without the extension prints '0' and '1' where C prints the member name
// @stdout: a-fast id#7 a-fast id#7 a-fast id#7 a-fast id#7 Busy
// note: an enum and a distinct type with a `toString` extension are rendered through it by echo, String, concatenation and interpolation, and a same-named enum of another module that has none keeps its default text instead of borrowing the extension.
import { fastA, idA } from "./a";
import { busyB } from "./b";

const mode = fastA();
const id = idA();
console.log(mode, id, String(mode), String(id), "" + mode + " " + id, `${mode} ${id}`, busyB());
