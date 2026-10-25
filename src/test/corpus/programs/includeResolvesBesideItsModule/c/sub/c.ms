@include("./x.h");

extern function fromC(): int32;

export function callC(): int32 {
	return fromC();
}
