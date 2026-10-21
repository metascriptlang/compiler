function mark(): string { return "?"; }

export function tag(a: string, b: string = mark()): string { return a + b; }
