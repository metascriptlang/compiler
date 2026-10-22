import { isPlainObject } from "std/typetraits";

export interface Proxy<T, H> { t: T; h: H; }

export function userProxyIsPlain(): boolean { return isPlainObject<Proxy<number, string>>(); }
