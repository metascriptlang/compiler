// @stdout: method macro ran|Table<Card>|Table<Card>|Table<Card>|Box<Card>|{column,owner}|real method|field fn|{typeOfM}|two|Table<Card>|Table<Card>|stmt ran
// @exit: 0
// note: `x.m(args)` is `m(x, args)` when `m` is a macro whose first parameter is `this` (the dot-call transformation); getType(src) answers (a class or struct receiver arrives as its field list, a generic instance by name) the receiver's checked type. A method or a function-typed field of the same name on the receiver wins; a non-function field does not block the macro.

import { Node, NodeKind, bindSym, createNodeAt } from "std/meta";
import { Table, typeOfM, twoM, whereM } from "./macros";

struct Card {
	column: string;
	owner: uint32;
}

class Box<T> { item: T | null = null; }
class Holder { cards: Table<Card> = new Table<Card>("held"); }
class Real {
	typeOfM(): string { return "real method"; }
}
class WithFnField {
	typeOfM: () => string = (): string => "field fn";
}
class WithNumberField {
	typeOfM: number = 3;
}

const out: string[] = [];
function record(text: string): void { out.push(text); }

macro noteM(this src: Node): Node {
	return createNodeAt(NodeKind.CallExpr, {
		callee: bindSym("record")!,
		arguments: [createNodeAt(NodeKind.StringLiteral, { value: "stmt ran" }, src.location)],
		isDirectCall: false, resolvedOverloadIdx: -1,
	}, src.location);
}

function viaGeneric<T>(table: Table<T>): string { return table.typeOfM(); }
function viaGenericBox<T>(box: Table<T>): void { box.noteM(); }

function makeCards(): Table<Card> { return new Table<Card>("made"); }

const cards = new Table<Card>("cards");
const holder = new Holder();
const box = new Box<Card>();
const card: Card = { column: "todo", owner: 1 };
const withNumber = new WithNumberField();
out.push(cards.whereM((c: Card) => c.column == "todo"));
out.push(cards.typeOfM());
out.push(holder.cards.typeOfM());
out.push(makeCards().typeOfM());
out.push(box.typeOfM());
out.push(card.typeOfM());
out.push(new Real().typeOfM());
out.push(new WithFnField().typeOfM());
out.push(withNumber.typeOfM());
out.push(cards.twoM(1, 2));
out.push(viaGeneric<Card>(cards));
out.push(viaGeneric(makeCards()));
viaGenericBox(cards);
console.log(out.join("|"));
