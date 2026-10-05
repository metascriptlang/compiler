// @stdout: C B A C | Auto | Q R P | Lit,Dim
// @xfail(raiser): Raiser prints an enum as its number (card 2026-09-25-raiser-enum-to-string-prints-the-number)
// note: an enum's name is printed wherever its value comes from — a call, a parameter, an annotated local, a struct field, a module that never names a member, a generic instance in another module — and an enum with explicit values prints the member that holds the value. C failed to build ("call to undeclared function 'Kind_toString'") when no member of the enum was named in its module, and printed "<unknown>" for an explicit value.

import { describe } from "./lib/hidden";
import { joinNames } from "./lib/names";

enum Kind { A, B, C }
enum Holes { P = 1, Q = 5, R = 9 }
enum Shade { Dim, Lit }
struct Tagged { kind: Kind; }

function conv(n: int32): Kind { return n as Kind; }
function shown(k: Kind): string { return k.toString(); }
function tagged(n: int32): Tagged { return { kind: n as Kind }; }
function hole(n: int32): Holes { return n as Holes; }
function shades(a: Shade, b: Shade): string { return joinNames([a, b]); }

const k: Kind = conv(0);
console.log(`${conv(2).toString()} ${shown(conv(1))} ${k.toString()} ${tagged(2).kind.toString()} | ${describe(2)} | ${hole(5).toString()} ${hole(9).toString()} ${hole(1).toString()} | ${shades(1 as Shade, 0 as Shade)}`);
