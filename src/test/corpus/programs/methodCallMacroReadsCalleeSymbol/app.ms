import { Query, ReadContext, WriteContext } from "./sdk";

export struct Card {
	id: uint32;
	column: string;
}

export function moveCard(ctx: WriteContext, { id, column }: { id: uint32; column: string }): void {}

export function columnCards(ctx: ReadContext, { column }: { column: string }): Query<Card> {
	return { name: "columnCards" };
}
