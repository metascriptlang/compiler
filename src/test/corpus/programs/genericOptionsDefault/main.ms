// @stdout: on nolabel|on nolabel|off nolabel|on nolabel|on|off|off none|on x|lib on nolabel nobefore|lib off nolabel nobefore
// note: an omitted options argument whose parameter is an instance of a generic interface is
// built from its default as that instance, so the omitted fields read as null on C and JS.
import { Opts, libMake } from "./lib";

struct Box<P> {
	inner: P;
}

function make<C>(value: C, options: Opts<C> = {}): string {
	const flag = options.flag ?? true;
	const label = options.label;
	return (flag ? "on" : "off") + (label === null ? " nolabel" : " label");
}

function wrap<C>(value: C, options: Opts<Box<C>> = {}): string {
	const flag = options.flag ?? true;
	return flag ? "on" : "off";
}

function optionsFirst<C>(options: Opts<C>, value: C): string {
	const flag = options.flag ?? true;
	const label = options.label;
	return (flag ? "on" : "off") + " " + (label === null ? "none" : label(value) ?? "null");
}

console.log(make<int32>(1) + "|" + make(1) + "|" + make(1, { flag: false }) + "|" + make("s")
	+ "|" + wrap(1) + "|" + wrap<int32>(2, { flag: false })
	+ "|" + optionsFirst({ flag: false }, 1) + "|" + optionsFirst({ label: (v: int32) => "x" }, 1)
	+ "|lib " + libMake<string>("a") + "|lib " + libMake(1, { flag: false }));
