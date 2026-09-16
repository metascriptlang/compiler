# MetaScript Standard Library

Standard library files under `std/` are **normal MetaScript code**. The compiler auto-imports system modules into every user module.

## System Modules

| Module | Provides | Auto-imported |
|--------|----------|---------------|
| `std/core.ms` | `assert`, `panic`, `len`, `toString`, `parseInt`, `parseFloat` | Yes |
| `std/math.ms` | `Math.floor()`, `Math.pi`, ... | Yes |
| `std/console.ms` | `console.log()`, `console.error()` | Yes |
| `std/promise.ms` | `Promise.resolve()`, `Promise.then()`, ... | Yes |
| `std/string.ms` | `str.trim()`, `str.split()`, ... | Yes |
| `std/array.ms` | `arr.push()`, `arr.pop()`, ... | Yes |

## How std Files Are Written

### Global Class + Static Extensions (Math, Console)

Class provides the type, value, and constant fields. Static extensions provide methods:

```ms
// std/math.ms — both class methods and static extensions work

export class Math {
    pi: number = 3.141592653589793;
    e: number = 2.718281828459045;

    @runtime("ms_floor")
    floor(x: number): number { unreachable; }

    @runtime("ms_ceil")
    ceil(x: number): number { unreachable; }
}

// static extensions also work
@runtime("ms_abs")
export function abs(this typeof Math, x: number): number { unreachable; }
```

### Global Type + Static Extensions (Promise, Result)

```ms
// std/promise.ms
export class Promise<T> {}

@runtime("ms_promise_resolve")
export function resolve<T>(this typeof Promise, value: T): Promise<T> { unreachable; }

@runtime("ms_promise_then")
export function then<T>(this p: Promise<T>, cb: (value: T) => void): void { unreachable; }
```

### Instance Extensions (String, Array)

```ms
// std/string.ms
@runtime("ms_string_trim")
export function trim(this s: string): string { unreachable; }

@runtime("ms_string_split")
export function split(this s: string, sep: string): string[] { unreachable; }
```

```ms
// std/array.ms
@runtime("ms_array_push")
export function push<T>(this arr: T[], elem: T): void { unreachable; }

@runtime("ms_array_pop")
export function pop<T>(this arr: T[]): T { unreachable; }
```

## Extension Types

| Type | Syntax | Example |
|------|--------|---------|
| Instance | `this varName: Type` | `this s: string` → `str.trim()` |
| Static | `this typeof Type` | `this typeof Math` → `Math.floor(x)` |

## Compiler Mechanism

1. Compiler has a hardcoded default `globalImports` list (std/core, std/math, std/console, ...)
2. Concatenates `globalImports` from `build.ms` after that default list (add-only, never replaces)
3. Parse each listed `.ms` file (normal parser)
4. Type-check (all 3 passes)
5. Inject exported symbols into Global scope
6. User code runs in child Module scope (can shadow)

## Call Resolution

```
Math.pi         → property access on global Math instance → 3.141592653589793
Math.floor(3.7) → static extension, resolved through the Math namespace → builtinLower → ms_floor(3.7)
str.trim()      → instance extension → trim(str) → builtinLower → ms_string_trim(str)
Promise.resolve(42) → static extension, resolved through the Promise namespace → builtinLower → ms_promise_resolve(42)
```

A static extension is NOT a module-scope name: `floor(3.7)` written bare is
`Undefined variable 'floor'`, and a user function named `floor` does not shadow
or collide with `Math.floor`. Instance extensions keep the UFCS pair — both
`str.trim()` and `trim(str)` resolve.

Same-named routines of one module coexist — a static `scale(this typeof Unit,…)`
next to a free `scale(…)`, or statics on two receivers sharing a name. Each
routine's emitted name carries a per-(module, name) ordinal minted at its
declaration (the `_uN` suffix), so the two never collapse into one symbol.
