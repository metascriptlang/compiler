# MetaScript bundler adapters

Public options and entry points are defined by the adjacent `.d.ts` files.

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

The override in this plugin's own development package does not propagate into an application's dependency tree. Ordinary non-watch builds do not require this repaired host.

## Maintaining the vendored host

`vendor/rollup4.json` owns input identities and artifact integrity; `vendor/buildRollup.mjs` owns the rebuild recipe. Run it through the workspace's remote-job wrapper, not on the shared editing machine. Its build-toolchain requirement is separate from the package's runtime engine declaration.

The patches follow Rollup's canonical source and existing dependency-patching mechanism. Rebase and verify them on each upstream upgrade. Replace the vendored host with an upstream release only after the retained immediate-write, error/deletion/recreation, native-backend and CLI controls pass; upgrading the version number alone is not evidence. No registry publication is part of this delivery.
