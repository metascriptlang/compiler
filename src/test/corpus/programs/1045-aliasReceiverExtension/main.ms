// @stdout: 42 hey! 10
// note: an extension declared on an alias receives the aliased type's values: `type Meters = int32` is int32 itself, so `plain.twice()` finds it, on an integer and on a string alias alike. The receiver is matched by its checked type, never by the alias's spelling.
import { twice, shout, Meters } from "./a";

const plain: int32 = 21;
const wrapped: Meters = 5;
const word: string = "hey";
console.log(`${plain.twice()} ${word.shout()} ${wrapped.twice()}`);
