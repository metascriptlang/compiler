import { Val, Box, Derived } from "./val";
export class Factory {
	static make(v: int32): Val { return new Val(v); }
}
export function boxOf(s: string): Box<string> { return new Box<string>(s); }
export function derived(): Derived { return new Derived(); }
