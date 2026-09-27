export function wrap<T>(x: T): string { return `B${x}`; }
export function wrapTwice<T>(x: T): string { return wrap(x) + wrap(x); }
