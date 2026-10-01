// @xfail(raiser): raiser runtime error: cannot evaluate 'direct' at comptime: symbol kind is Module
// @stdout: module abc

import * as direct from "./library";
import * as viaHub from "./hub";
import { Bag, recordBagValue as named } from "./hub";

const bag: Bag = { values: [] };
direct.recordBagValue(bag, "a");
viaHub.recordBagValue(bag, "b");
named(bag, "c");
console.log(`module ${bag.values[0]}${bag.values[1]}${bag.values[2]}`);
