export struct Cell { text: string; }

export function toString(this c: Cell): string { return "A(" + c.text + ")"; }

export function makeCellA(): Cell { return { text: "left" }; }
