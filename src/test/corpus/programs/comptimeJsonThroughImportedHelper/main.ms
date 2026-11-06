// @stdout: helper [[[]],{"x":"\ud800"}] | [[[]],{"x":"\ud800"}]
// @stdout: wide {"k0":"end","k1":27,"k2":28,"k3":29,"k4":30,"k5":31,"k6":32,"k7":33,"k8":34,"k9":35,"k10":36,"k11":37,"k12":38} | {"k0":"end","k1":27,"k2":28,"k3":29,"k4":30,"k5":31,"k6":32,"k7":33,"k8":34,"k9":35,"k10":36,"k11":37,"k12":38}
// @stdout: macro {"m":2} | {"m":2}
// note: parseJson reached through a helper of another module, from a comptime block and from a macro, answers what the same call answers at run time; the wide object takes the parser's Map dedupe path.
import { roundTrip, wide } from "./lib";
import { Node, NodeKind } from "std/meta";

macro viaMacro(): Node {
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: roundTrip("{\"m\":[1,{\"k\":null}],\"m\":2}") };
}

const helper = @comptime { return roundTrip("[[[]],{\"x\":\"\\ud800\"}]"); };
const wideAtComptime = @comptime { return roundTrip(wide(40, 13)); };
console.log(`helper ${helper} | ${roundTrip("[[[]],{\"x\":\"\\ud800\"}]")}`);
console.log(`wide ${wideAtComptime} | ${roundTrip(wide(40, 13))}`);
console.log(`macro ${viaMacro()} | ${roundTrip("{\"m\":[1,{\"k\":null}],\"m\":2}")}`);
