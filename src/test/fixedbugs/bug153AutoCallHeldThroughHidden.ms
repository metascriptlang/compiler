// bug153 — an accessor callee re-checked through a hidden conversion was auto-called twice
//
// Symptom:    `const view = <p>{c()}</p>` consumed by a macro emitted `c()()`: the js lane
//             threw "c(...) is not a function", the C lane failed with "called object type
//             'msString' is not a function". Found by Neon's element.test.ms ("JSX bound to a
//             const is consumed by element()").
//
// Root cause: foldComptimeNodeAliasArgs clones the already-checked JSX into the macro
//             argument; the clone drops Sem but keeps the HiddenStdConv the callee peel wrapped
//             around `c`. On the re-check the auto-call hold pointed at the wrapper while the
//             Identifier underneath was checked through the HiddenStdConv arm, so it no longer
//             matched the hold and was rewritten into a call.
//
// Fix:        autoCallIfAccessor compares the hold peeled through hidden conversions and derefs
//             (peelHidden), so a callee stays a callee however many hidden nodes wrap it.

import { Node } from "std/meta";

type Acc153<T> = distinct (() => T);

export macro firstExpr153(n: Node): Node { return n.jsxChildren[0].jsxExpr; }

test "bug153: a const JSX alias re-checked through a macro calls the accessor once" {
	const c = (() => 7) as Acc153<number>;
	const view = <p>{c()}</p>;
	const v: number = firstExpr153(view);
	assert v === 7;
}

test "bug153: a string accessor survives the same path" {
	const s = (() => "hi") as Acc153<string>;
	const view = <p>{s()}</p>;
	const v: string = firstExpr153(view);
	assert v === "hi";
}

test "bug153: an implicit read inside the const JSX is called exactly once" {
	const c = (() => 5) as Acc153<number>;
	const view = <p>{c * 2}</p>;
	const v: number = firstExpr153(view);
	assert v === 10;
}
