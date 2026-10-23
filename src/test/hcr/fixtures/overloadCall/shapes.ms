export function put(s: string): string {
	return `s ${s}`;
}
export function put(n: int32): string {
	return `n ${n}`;
}
export function put(ns: int32[]): string {
	return `ns ${ns.length}`;
}
