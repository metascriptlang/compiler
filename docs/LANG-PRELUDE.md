# MetaScript Prelude (std/core)

## Overview

Every MetaScript module has automatic access to prelude symbols -- no import needed.
Compile prelude first, inject exports into every scope.

## Mechanism

1. Prelude symbols constructed programmatically in `src/checker/prelude.ms`
2. Injected into **Global scope** before user code runs
3. User code runs in a child **Module scope** -- can shadow prelude names
4. `lookupSymbol` walks scope chain: Module -> Global -> found

## Scope Model

```
Global scope (prelude: print, floor, ceil, len, ...)
  +-- Module scope (user declarations, imports, functions)
        +-- Function scope
              +-- Block scope ...
```

## Monomorphization Dependency

Generic prelude functions (e.g. `push<T>`, `then<T>`) require **eager monomorphization
integrated into the checker**. When the checker resolves a call like `arr.push(42)` where
`arr: number[]`:

1. Pass 3 matches `push<T>(this a: T[], elem: T)` against `number[]`
2. Infers `T = number`
3. Immediately clones + instantiates `push_number(this a: number[], elem: number)`
4. Transforms and codegen only see concrete instantiated functions

No separate monomorphize phase -- instantiation happens eagerly during type checking.

## Available Symbols

### I/O
| Function | Signature | C mapping |
|----------|-----------|-----------|
| `print`  | `(value: string): void` | `ms_print` |
| `println`| `(value: string): void` | `ms_println` |

### Math
| Function | Signature | C mapping |
|----------|-----------|-----------|
| `floor`  | `(x: number): number` | `ms_floor` |
| `ceil`   | `(x: number): number` | `ms_ceil` |
| `abs`    | `(x: number): number` | `ms_abs` |
| `min`    | `(a: number, b: number): number` | `ms_min` |
| `max`    | `(a: number, b: number): number` | `ms_max` |
| `sqrt`   | `(x: number): number` | `ms_sqrt` |
| `round`  | `(x: number): number` | `ms_round` |

### Conversion
| Function | Signature | C mapping |
|----------|-----------|-----------|
| `toString` | `(value: number): string` | `ms_to_string` |
| `parseInt` | `(s: string): number` | `ms_parse_int` |
| `parseFloat`| `(s: string): number`| `ms_parse_float` |

### Assertions
| Function | Signature | C mapping |
|----------|-----------|-----------|
| `assert` | `(condition: boolean): void` | `ms_assert` |
| `panic`  | `(msg: string): void` | `ms_panic` |

### String Builtins
| Function | Signature | Builtin Kind |
|----------|-----------|-------------|
| `len`    | `(s: string): number` | `LengthStr` |

## Extension Methods

Extension methods use `this` receiver syntax. The checker registers them in the
ExtensionRegistry; `extensionMethodLower` rewrites `obj.method(args)` to `method(obj, args)`;
`builtinLower` rewrites to the C runtime name.

### String Extensions
```ms
@runtime("ms_string_trim")
export function trim(this s: string): string { unreachable; }

@runtime("ms_string_split")
export function split(this s: string, sep: string): string[] { unreachable; }

@runtime("ms_string_starts_with")
export function startsWith(this s: string, prefix: string): boolean { unreachable; }

@runtime("ms_string_ends_with")
export function endsWith(this s: string, suffix: string): boolean { unreachable; }
```

### Array Extensions (Generic)
```ms
@runtime("ms_array_push")
export function push<T>(this arr: T[], elem: T): void { unreachable; }

@runtime("ms_array_pop")
export function pop<T>(this arr: T[]): T { unreachable; }

@runtime("ms_array_length")
export function length<T>(this arr: T[]): number { unreachable; }

@runtime("ms_array_slice")
export function slice<T>(this arr: T[], start: number, end: number): T[] { unreachable; }
```

### Promise Extensions (Generic)
```ms
@runtime("ms_promise_then")
export function then<T>(this p: Promise<T>, cb: (value: T) => void): void { unreachable; }

@runtime("ms_promise_catch")
export function catch<T>(this p: Promise<T>, cb: (error: string) => void): void { unreachable; }

@runtime("ms_promise_resolve")
export function resolve<T>(value: T): Promise<T> { unreachable; }
```

### Call Resolution Flow

```
user code:    arr.push(42)           // arr: number[]
checker:      match push<T>(T[], T) against (number[], number) -> T = number
              instantiate: push_number(number[], number)
extension:    push_number(arr, 42)
builtin:      ms_array_push(arr, 42)
codegen:      ms_array_push(arr, 42);
```

## Pipeline Integration

```
Source.ms
  -> [1 Parse]
  -> [2 Check]            <-- prelude injected (Global scope)
                           <-- eager monomorphization at each generic call site
  -> [3 Transform]        (27 general transforms, incl. extensionMethodLower)
  -> [3b TransformNative] (builtinLower rewrites @runtime/@builtin calls)
  -> [4 Analyze]          (DRC injection)
  -> [5 Codegen]          (C/JS output)
```

## Shadowing

User code can shadow any prelude symbol:

```ms
function floor(x: string): string { return x; }  // shadows prelude floor
const y = floor("hello");  // calls user's floor, not prelude
```

## Explicit Import

`import { X } from "std/core"` is a no-op -- symbols already in scope via prelude injection.
