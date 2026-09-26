// bug551 — a generic type whose body does not mention its parameter lost its body
//
// Symptom:    `type Phantom<T> = int32; const x: Phantom<boolean> = 3;` failed with "Type 'int32' is not
//             assignable to type 'Phantom'" once method-level generics were instantiated.
//
// Root cause: instantiateGenericBody left an instance without a body whenever substitution returned the
//             declaration unchanged, to keep `Box<U>` from sharing the class's own struct (whose fields
//             still read T while the class resolves); a body that never mentions T is unchanged too.
//
// Fix:        only a declared struct shared with its declaration is left for later; any other unchanged
//             body is the instance's body.

import { errorCount } from "../handoff/helpers";

test "bug551: an alias whose body ignores its parameter keeps the body" {
	assert errorCount("type Phantom551<T> = int32;\nconst x: Phantom551<boolean> = 3;\nconst y: Phantom551<string> = x + 1;\n") == 0;
	assert errorCount("type Label551<T> = string;\nfunction name551(l: Label551<int32>): string { return l + \"!\"; }\nconst n = name551(\"a\");\n") == 0;
}
