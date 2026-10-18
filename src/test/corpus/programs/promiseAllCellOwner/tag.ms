export struct Tag { label: string; n: int32; }
export async function mkTag(l: string, n: int32): Promise<Tag> { return { label: l, n }; }
export async function mkInt(n: int32): Promise<int32> { return n * 2; }
export async function mkBig(n: int64): Promise<int64> { return n + 1; }
