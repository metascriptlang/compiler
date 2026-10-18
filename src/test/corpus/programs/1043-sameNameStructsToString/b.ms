export struct Cell { count: int32; }

export function toString(this c: Cell): string { return "B(" + String(c.count) + ")"; }

export function makeB(): Cell { return { count: 7 }; }
