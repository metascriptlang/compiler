export class a__b { x: int32 = 1; }
export class Maybe_x { x: int32 = 2; }
export class msTuple_z { x: int32 = 3; }
export class msUnion_u { x: int32 = 4; }
export class g__x<T> { v: T; constructor(v: T) { this.v = v; } }
export function libTypes(v: unknown): string {
	return `${v instanceof a__b} ${v instanceof Maybe_x} ${v instanceof msTuple_z} ${v instanceof msUnion_u}`;
}
export function libValues(): string {
	return `${new a__b().x} ${new Maybe_x().x} ${new msTuple_z().x} ${new msUnion_u().x} ${new g__x<int32>(5).v}`;
}
