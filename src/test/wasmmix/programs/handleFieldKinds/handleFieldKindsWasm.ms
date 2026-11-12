import { Handle } from "std/ffi";

export enum Mode { Idle, Busy, Done }
export enum Level { Low = -1, High = 300 }

export class Gauge {
	label: string = "g";
	s8: int8 = -128;
	u8: uint8 = 255;
	s16: int16 = -32768;
	u16: uint16 = 65535;
	s32: int32 = -2147483648;
	u32: uint32 = 4294967295;
	s64: int64 = -9007199254740993;
	u64: uint64 = 18446744073709551615;
	f32: float32 = 1.25;
	f64: float64 = -2.5;
	on: boolean = true;
	mode: Mode = Mode.Busy;
	level: Level = Level.High;

	describe(): string {
		return `${this.s8} ${this.u8} ${this.s16} ${this.u16} ${this.s32} ${this.u32} ${this.s64} ${this.u64} ${this.f32} ${this.f64} ${this.on} ${this.mode as int32} ${this.level as int32}`;
	}
}

@wasm
export function open(): Handle<Gauge> {
	return Handle.retain(new Gauge());
}

@wasm
export function grow(n: int32): int32 {
	let xs: Vec<float64> = [];
	for (let i = 0; i < n; i += 1) xs.push(i as float64);
	return xs.length as int32;
}
