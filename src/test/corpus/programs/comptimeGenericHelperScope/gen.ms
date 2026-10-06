import { word } from "./tag";

export function tagValue<T>(): int32 {
	return @comptime { return word(T.tag()); };
}

export function viaOuter<U>(): int32 {
	return tagValue<U>();
}
