export enum Level { Low = 1, Mid = 2, High = 3 }

@wasm
export function stepNarrow(ref b: boolean, ref i8: int8, ref i16: int16, ref i32: int32, ref u8: uint8, ref u16: uint16, ref u32: uint32): int32 {
	b = !b;
	i8 = i8 - 1;
	i16 = i16 + 1;
	i32 = i32 * 2;
	u8 = u8 + 1;
	u16 = u16 - 1;
	u32 = u32 + 1;
	return i32 + 1;
}

@wasm
export function stepWide(ref i64: int64, ref u64: uint64, ref f32: float32, ref f64: float64): void {
	i64 = i64 * 2;
	u64 = u64 + 1;
	f32 = f32 / 4;
	f64 = f64 * 3;
}

@wasm
export function fillAll(out b: boolean, out i32: int32, out u32: uint32, out i64: int64, out u64: uint64, out f64: float64, out lvl: Level, out s: string): void {
	b = true;
	i32 = -7;
	u32 = 4294967295;
	i64 = -9007199254740993;
	u64 = 18446744073709551615;
	f64 = 0.1;
	lvl = Level.High;
	s = "filled é";
}

@wasm
export function stepText(ref s: string, ref lvl: Level): int32 {
	s = s + "!";
	lvl = lvl == Level.High ? Level.Low : Level.High;
	return s.length;
}

@wasm
export function flip(ref n: int32 | null, ref s: string | null, ref lvl: Level | null, ref f: float64 | null): void {
	n = n == null ? 1 : null;
	s = s == null ? "was null" : null;
	lvl = lvl == null ? Level.Mid : null;
	f = f == null ? 2.5 : null;
}

@wasm
export function fillThenThrow(out x: int32, ref y: int32, ref s: string, fail: boolean): void {
	x = 5;
	y = y + 1;
	s = s + " written";
	if (fail) throw new Error("boom after the writes");
}

@wasm
export function throwBeforeFill(out x: int32, fail: boolean): void {
	if (fail) throw new Error("boom before the write");
	x = 9;
}
