export struct Thing { tag: string; n: number; }

export function mk(n: number): Thing { return { tag: "t", n: n }; }
