export enum Stance207 { Guard, Strike, Rest }

export function cost(this stance: Stance207, base: int32): int32 {
	return base + (stance as int32);
}
