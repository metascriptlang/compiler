export struct Tag { x: int32; }

export function tagOf(n: int32): Tag {
	return { x: n };
}

export function word(this t: Tag): int32 {
	return t.x * 2;
}
