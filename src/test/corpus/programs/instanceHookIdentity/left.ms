import { Box, Marker, Ticket, id, phantom, ticket } from "./library";

enum Token { A, B }

export function left(): int32 {
	const box = new Box<Token>(id<Token>(Token.B));
	const marker = new Marker<Token>(2);
	const owned: Ticket<Token> = ticket<Token>(box.value, 3);
	return (owned.value as int32) + phantom<Token>(marker.tag);
}

export function leftShared(): int32 { return id<int32>(5); }
