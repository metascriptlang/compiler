@include("system.h");

class console {
  @runtime("msPrintln")
  log(value: string): void { unreachable; }
}
