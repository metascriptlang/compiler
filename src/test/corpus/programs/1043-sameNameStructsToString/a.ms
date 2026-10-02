export struct Cell { text: string; }

export function toString(this c: Cell): string { return "A(" + c.text + ")"; }

export function makeA(): Cell { return { text: "left" }; }
