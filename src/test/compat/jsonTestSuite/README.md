# JSONTestSuite

`suite/` is [JSONTestSuite](https://github.com/nst/JSONTestSuite) at commit `1ef36fa01286573e846ac449e8683f8833c5b26a` (`test_parsing`, `test_transform`, MIT `LICENSE`), copied byte for byte (`-text` in `.gitattributes`).

The oracle is node: `node.tsv` is what `JSON.parse` then `JSON.stringify` gives for each file, written by `node oracle.mjs`. A row of `decided.tsv` replaces node's row where the person chose a different result, with the reason in its third column. Regenerate `node.tsv` only when the suite is updated, and say which node version wrote it in the commit.

Run from the repository root, once per backend; exit 1 lists every file that differs:

```sh
msc run src/test/compat/jsonTestSuite/run.ms
msc run --target=js src/test/compat/jsonTestSuite/run.ms
msc run --target=raiser src/test/compat/jsonTestSuite/run.ms
```

`MSC=./msc` does not apply: the runner is the program under test, so run it with the candidate (`./msc run …`).
