// @stdout: declared=[] row:Card{column,owner} | declared=[] row:Card{column,owner} | declared=[Card] row:Card{column,owner} | declared=[] other
// note: a macro argument is checked against the macro's declared formal, with the macro's type parameters bound in argument order, so an unannotated lambda is typed from the receiver before the macro reads it (as an ordinary generic call types it). The body sees a function-typed formal as a Node. Variants: dot call and bare call, a second type parameter, a lambda with its own annotation, a `fn: Node` formal that stays untyped.

import { Table, where, whereOne, untyped } from "./macros";

struct Card {
	column: string;
	owner: uint32;
}

const cards = new Table<Card, string>();
console.log([
	cards.where(c => c.column == "todo"),
	where(cards, c => c.owner == 1),
	whereOne(cards, (c: Card) => c.column == "x"),
	untyped((c) => c.column),
].join(" | "));
