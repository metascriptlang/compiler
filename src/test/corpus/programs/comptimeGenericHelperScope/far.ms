import { Tag, tagOf } from "./tag";

export struct Far { v: int32; }

export function tag(this typeof Far): Tag {
	return @comptime { return tagOf(3); };
}
