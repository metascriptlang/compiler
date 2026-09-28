import { Cell } from "../lib/cell";

class Tag {
	name: string = "g";
}

export function run(): int32 {
	const tag = new Cell<Tag>(new Tag()).get();
	return (new Cell<int32>(6).get() + tag.name.length) as int32;
}
