// Companion for structuralMaybeHookNaming. The same Maybe<number|string|null>
// is reachable two ways from here: inline in a field, which carries no symbol,
// and through the SV alias, whose symbol belongs to this module.

export interface Own {
	w: number | string | null;
	h: number | string | null;
}

export type SV = number | string | null;

export function setField(o: Own, name: string, v: SV): void {
	if (name == "w") { o.w = v; return; }
	o.h = v;
}
