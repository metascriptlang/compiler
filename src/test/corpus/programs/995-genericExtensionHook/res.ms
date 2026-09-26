let resTrail = "";

export function resDestroyed(): string {
	return resTrail;
}

export interface Res<T> {
	v: T;
	h: int32;
}

export function onDestroy<T>(this self: Res<T>): void {
	resTrail = resTrail + " r" + self.h.toString();
}

export function res<T>(v: T, h: int32): Res<T> {
	return { v: v, h: h };
}
