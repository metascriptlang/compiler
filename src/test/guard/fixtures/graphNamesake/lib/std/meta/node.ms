export class Type { kids: Type[] = []; back: Type | null = null; }

export function depthOf(t: Type): int32 { return t.kids.length as int32; }
