let markerTotal: int32 = 0;
let ticketTotal: int32 = 0;

export class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}

export class Marker<T> {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void { markerTotal += this.tag; }
}

export struct Ticket<T> { value: T; tag: int32; }

function onDestroy<T>(this ref self: Ticket<T>): void { ticketTotal += self.tag; }

export function totals(): int32 { return markerTotal * 100 + ticketTotal; }

export function id<T>(value: T): T { return value; }

export function phantom<T>(value: int32): int32 { return value + 1; }

export function repeat<T>(value: T, count: int32): T {
	if (count == 0) return value;
	return repeat<T>(value, count - 1);
}

export function ticket<T>(value: T, tag: int32): Ticket<T> { return { value: value, tag: tag }; }
