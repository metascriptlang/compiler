@passC("-I./inc");
@passC("-I../passCRelShared");
@include("passcRelDot.h");
@include("passcRelDotDot.h");

extern function passcRelDotValue(): int32;
extern function passcRelDotDotValue(): int32;

export function relDot(): int32 { return passcRelDotValue(); }
export function relDotDot(): int32 { return passcRelDotDotValue(); }
