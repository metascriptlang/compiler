// Companion for crossModuleMaybeEq. The Maybe wrapping this union is 32 bytes,
// past the pointer-introduction threshold, so its Eq hook takes its operand by
// pointer. Comparing here makes THIS module define the hook; the importing
// module only ever sees a forward declaration.

export type WV = number | string | null;

export function sameValue(a: WV, b: WV): boolean {
	return a == b;
}
