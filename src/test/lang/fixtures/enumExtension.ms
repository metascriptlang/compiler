export enum ImportedStance { Guard, Strike, Rest }

export function cost(this stance: ImportedStance, base: int32): int32 {
	return base + (stance as int32);
}
