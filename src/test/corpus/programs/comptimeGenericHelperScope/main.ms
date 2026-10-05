// @stdout: own 14 far 6 nested 14 6
// @exit: 0
// A compile-time helper resolves its names in the module that declares it, also when the
// generic that calls it is instantiated by that same module and its own module imports none of them.
import { Tag, tagOf } from "./tag";
import { tagValue, viaOuter } from "./gen";
import { Far } from "./far";

export struct Kind { v: int32; }

export function tag(this typeof Kind): Tag {
	return @comptime { return tagOf(7); };
}

console.log(`own ${tagValue<Kind>()} far ${tagValue<Far>()} nested ${viaOuter<Kind>()} ${viaOuter<Far>()}`);
