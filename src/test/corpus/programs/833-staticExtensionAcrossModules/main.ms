// @stdout: statics block=9 pet=7 free=5 mood=1 kinds=2,1
// note: one module exports a free `create` and two static `create`s, an enum static and a generic that calls `T.accountKind()`; the importer declares the `accountKind` statics. Every static reaches the importer as an extension and never as a bare name, and on JS each keeps an export binding of its own.
import { Pet, Block, Mood, create, fromByte, kindOf } from "./lib";

export struct Coin { v: uint8; }
export function accountKind(this typeof Pet): uint8 { return 2; }
export function accountKind(this typeof Coin): uint8 { return 1; }

const mood = Mood.fromByte(1) == Mood.Angry ? 1 : 0;
console.log(`statics block=${Block.create().id} pet=${Pet.create().hunger} free=${create(4)} mood=${mood} kinds=${kindOf<Pet>()},${kindOf<Coin>()}`);
