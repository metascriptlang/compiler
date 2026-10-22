// @stdout: 1 2 3 7|true true false|4 2|4 5 3 3 5 99
// note: the std Proxy is known by its declaration, not its spelling: a user type named Proxy
// stays a plain type, the std one keeps its traps under an alias or beside the user type, and
// the std routines a proxy use is rewritten into are reached past user ones of the same name.
import { isPlainObject } from "std/typetraits";
import { newProxy, Proxy as SP } from "std/core/proxy";
import { Proxy as Shape, userProxyIsPlain } from "./lib";
import { shadowedNew } from "./shadow";
import { shadowedHelpers } from "./helpers";

class Proxy { z: number = 7; }
class Handler {}

const a = newProxy({ a: 1 }, new Handler());
const b = new SP({ a: 2 }, new Handler());
const c: SP<{ a: number }, Handler> = newProxy({ a: 3 }, new Handler());
console.log(`${a.a} ${b.a} ${c.a} ${new Proxy().z}|${userProxyIsPlain()} ${isPlainObject<Shape<number, string>>()} ${isPlainObject<SP<{ a: number }, Handler>>()}|${shadowedNew()}|${shadowedHelpers()}`);
