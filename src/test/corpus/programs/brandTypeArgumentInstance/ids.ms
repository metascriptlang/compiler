export type Id = int32 & { __brand: "Id" };

export struct Box<T> {
	v: T;
}

export function boxedId(n: int32): Box<Id> {
	return { v: n as Id };
}
