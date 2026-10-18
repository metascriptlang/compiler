// @stdout: 1,a,2
// @stdout: true,false
// @xfail(raiser): the raiser writes an array nested inside a union value as [array]
// note: a union alias that names itself converts to text through each member, directly, through a generic parameter, and one level deeper; before, naming the type looped until the stack ran out.
type Json = string | number | Json[];
type Flags = boolean | Flags[];

function show<T>(v: T): string {
	return `${v}`;
}

const j: Json = [1, "a", [2]];
const t: Flags = [true, [false]];
console.log(`${j}`);
console.log(show(j));
console.log(`${t}`);
