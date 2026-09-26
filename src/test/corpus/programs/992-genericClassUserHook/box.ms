let remoteTrail = "";

export function remoteDestroyed(): string {
	return remoteTrail;
}

export class Remote<T> {
	v: T;
	h: int32;
	constructor(v: T, h: int32) { this.v = v; this.h = h; }
	onDestroy(): void { remoteTrail = remoteTrail + " r" + this.h.toString(); }
}
