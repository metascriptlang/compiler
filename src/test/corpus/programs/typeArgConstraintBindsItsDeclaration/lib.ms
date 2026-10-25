type Keys = "a" | "b";

export interface Model { id: int32; }
export type At<T, K extends keyof T> = T[K];
export interface Slot<T, K extends keyof T> { v: T[K]; }
export class Cell<T, K extends keyof T> {
	v: T[K];
	constructor(v: T[K]) { this.v = v; }
}
export type Sub<T, U extends T> = U;
export type Tagged<T, K extends Keys> = T;
export interface Store<T extends Model> { item: T; }
