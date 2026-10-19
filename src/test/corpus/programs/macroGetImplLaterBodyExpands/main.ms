// @stdout: 1 1 1 1 1 1 1 1 1 1|10 20 7 3 8 8 42 18 22
// @exit: 0
// note: a macro reads with `getImpl` a function declared further down whose body itself calls a macro, at module level, inside a function, two such bodies deep, through a @comptime block and a field decorator in that body. Checking the later body runs the compile-time VM again from inside the first macro's run; the first run used to be lost, failing the build with "Undefined variable 'int32'", crashing the compiler, or folding the inner value (42) in place of the outer macro's result. A later class, a later generic and an import cycle never re-entered and stay as controls.

import { hasImpl, hasImplNamed, typed, twice, same, doubled } from "./meta";
import { viaCycle, fromCycle } from "./cyc";
import { peerSees } from "./cycPeer";

const atModule = hasImpl(lateAtModule);

function outer(): int32 { return hasImpl(late); }
function deep(): int32 { return hasImpl(middle); }
function viaClass(): int32 { return hasImpl(Later); }
function viaGeneric(): int32 { return hasImplNamed("pick"); }
function viaComptime(): int32 { return hasImpl(folded); }
function viaDecorator(): int32 { return hasImpl(decorated); }
function viaImport(): int32 { return hasImpl(fromCycle); }

function lateAtModule(): int32 { return twice(5); }
function late(): int32 { return typed(20); }
function middle(): int32 { return hasImpl(bottom) + twice(bottom()); }
function bottom(): int32 { return typed(3); }
class Later {
	value(): int32 { return twice(4); }
}
function pick<T>(a: T): T { return same(a); }
function folded(): int32 { return @comptime { return 6 * 7; }; }
function decorated(): int32 {
	class Box {
		@doubled size: int32 = 9;
	}
	return new Box().size;
}

const found = [atModule, outer(), deep(), viaClass(), viaGeneric(), viaComptime(), viaDecorator(), viaImport(), viaCycle(), peerSees()];
const ran = [lateAtModule(), late(), middle(), bottom(), new Later().value(), pick(8), folded(), decorated(), fromCycle()];
console.log(found.join(" ") + "|" + ran.join(" "));
