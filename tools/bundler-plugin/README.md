# MetaScript bundler adapters

Public options and entry points are defined by the adjacent `.d.ts` files.

## Source discovery skips node_modules

In source-declaration watch, the webpack and Rollup adapters find new sources under the project root but never enter a directory named `node_modules`: the webpack source inventory does not read it, and neither watcher descends into it (Vite's own watcher already ignores it). Files the compiler reports as dependencies stay watched one by one. A MetaScript package installed after an import of it failed is therefore picked up on the next edit of a project source or a restart. With a glob `watchOptions.ignored`, webpack cannot exclude the directory without its files, so it keeps watching `node_modules` unless those globs cover it.

## Rollup source-declaration watch

This mode needs the patched host identified by `rollup.js`'s `options` hook. It refuses an unqualified host instead of starting a watch session that can silently miss recovery.

Rollup bundles its watcher dependency; an application-level Chokidar override cannot repair that embedded code. The vendored Rollup retains the upstream native-parser ABI. Its separate public version identifies the JavaScript watcher repair, not a new compiler output format.

Copy `vendor/rollup4.tgz` into your application's **tracked** `vendor/rollup4.tgz`, then select it at the application root:

```json
{
  "devDependencies": {
    "rollup": "file:vendor/rollup4.tgz"
  },
  "overrides": {
    "rollup": "$rollup"
  }
}
```

Install normally after merging these fields with existing configuration. The root override also selects the host used by Vite. Do not reference a tarball inside `node_modules`: a clean install removes that directory. Other package managers need their corresponding root-level override and actual host-resolution verification.

The test harness's own override (`harness/package.json`) does not reach an application's dependency tree. Ordinary non-watch builds do not require this repaired host.

## Webpack source-declaration watch

The adapter adds its output exclusions to `watchOptions.ignored` in the shape the configured value already has: one RegExp for a RegExp or nothing, globs after a glob or glob list, a function around a function. Every watchpack 2.x that webpack 5 can resolve accepts those shapes; watchpack refuses RegExp items in an array before 2.6.0 and functions before 2.3.0. A project path containing `* ? [ ] { }` cannot be written as a glob, so with a glob `ignored` it needs watchpack 2.6.0 or later, and the adapter's error names that case on an older one. Checked with each shape against watchpack 2.0.0, 2.2.0, 2.3.1, 2.4.4, 2.5.2, 2.6.3 and 2.6.4 by reading back each version's normalized matcher: plugin outputs ignored, sources and the user's own pattern kept.

A directory the plugin creates inside the project (the declaration `outDir`, and `node_modules/.metascript` when a glob `ignored` keeps `node_modules` watched) wakes one more webpack generation, which compiles nothing. The project root is a context dependency, so a new entry in it is a change, and ignoring the directory would also stop watching sources placed in it. Suppressing that generation was rejected: webpack's `invalid` hook has already fired for the change, and swallowing the aggregated callback means re-arming the watcher, which races an edit made in between.

## Testing the adapters

`test.mjs` is the gate's entry: it runs the native adapter tests and the real-compiler consumers in `src/test/js/declarationBundlers/run.mjs`. The pinned bundlers live in the private `harness/` package, installed with `npm ci` from its lockfile and linked as this directory's `node_modules`, so the adapters and their `.d.ts` resolve bare imports as they do in an application. The plugin's own `package.json` lists only what applications install: bun installs a `file:` dependency's devDependencies and resolves their relative paths from the application, so test tooling there broke `bun install`. The lockfile exists because the transitive tree used to float: watchpack 2.6.x arrived unpinned and changed watch behaviour between gates. Cost on rtx: 55–91 s at low load.

Traps a watch test meets, each paid for with a red gate:

- **A file written just before a webpack watch starts is reported as changed.** watchpack treats a file as possibly modified while its mtime plus filesystem accuracy (up to 2 s) reaches the watch start, so a fixture file can wake an extra generation, or invalidate declarations, whenever the host is slow. Fixtures settle such files 10 s into the past (`settle` in `webpack.test.js`) and keep their own control files, such as the compiler call counter, outside the watched root.
- **Synchronous work blocks `node:test` timeouts.** A consumer test running `tsc` through `spawnSync` cannot be interrupted, so a test over budget fails at the next `await` and looks like a bundler hang. On rtx gates the failing `webpack-watch-established` runs took 87–92 s against a 60 s budget, the passing ones 8–24 s. `skipDefaultLibCheck` halves `tsc` time without skipping the generated declarations.
- **Deadlines come from a loaded measurement.** Pin the test and six CPU burners to two cores (`taskset`), which loads the test about 4× without loading the shared host. On tree `dac51bad01eccc62379b6dac8214e0d091f9b1ac` the watch consumers took 39–47 s and every native watch test under 8 s; watch consumer deadlines are 180 s, `tsc` 60 s, native watch tests 15 s.
- **Watchpack versions differ in what `ignored` accepts** (§Webpack source-declaration watch). To check a shape against another version, construct that version's `Watchpack` with the adapter's options and read back its normalized `watcherOptions.ignored`, as `webpack.test.js` does for the installed one.

## Maintaining the vendored host

`vendor/rollup4.json` owns input identities and artifact integrity; `vendor/buildRollup.mjs` owns the rebuild recipe. Run it through the workspace's remote-job wrapper, not on the shared editing machine. Its build-toolchain requirement is separate from the package's runtime engine declaration.

The patches follow Rollup's canonical source and existing dependency-patching mechanism. Rebase and verify them on each upstream upgrade. Replace the vendored host with an upstream release only after the retained immediate-write, error/deletion/recreation, native-backend and CLI controls pass; upgrading the version number alone is not evidence. No registry publication is part of this delivery.
