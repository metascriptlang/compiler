@include("runtime.h");

class console {
  @runtime("ms_println")
  log(value: string): void { unreachable; }
}
