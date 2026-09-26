export function trim<T>(this x: T): string { return "generic"; }

export function direct(s: string): string { return s.trim(); }

export function inGeneric<T>(tag: T, s: string): string { return s.trim(); }

export function onValue<T>(x: T): string { return x.trim(); }
