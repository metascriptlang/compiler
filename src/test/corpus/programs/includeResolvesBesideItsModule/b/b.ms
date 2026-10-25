@include("x.h");

extern function fromB(): int32;

export function callB(): int32 {
	return fromB();
}
