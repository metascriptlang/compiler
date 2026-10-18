import { Box, Marker, Ticket, id, phantom, ticket } from "./library";

enum Token { A, B }

export function right(): int32 {
	const box = new Box<Token>(id<Token>(Token.A));
	const marker = new Marker<Token>(5);
	const owned: Ticket<Token> = ticket<Token>(box.value, 7);
	return (owned.value as int32) + phantom<Token>(marker.tag);
}

export function rightShared(): int32 { return id<int32>(11); }
