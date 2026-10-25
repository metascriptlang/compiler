const assert = require('node:assert/strict');
const fs = require('node:fs');
const { WASI } = require('node:wasi');

async function main() {
    const [file, mode = 'plain'] = process.argv.slice(2);
    const wasi = new WASI({ version: 'preview1', args: [file], env: {}, returnOnExit: true });
    const calls = [];
    let instance;
    let entropyCalls = 0;
    let clockCalls = 0;
    const wasiImports = { ...wasi.wasiImport };
    if (mode === 'platform' || mode === 'clockFailure') {
        // Deliberate host responses test callback contracts, not entropy quality.
        wasiImports.random_get = (pointer, length) => {
            assert.equal(length, 16);
            entropyCalls++;
            if (entropyCalls === 2) return 29; // IO error.
            assert.equal(entropyCalls, 1);
            new Uint8Array(instance.exports.memory.buffer, pointer, length).fill(42);
            return 0;
        };
        wasiImports.clock_time_get = (clock, precision, pointer) => {
            assert.equal(clock, 1); // Monotonic clock.
            assert.equal(precision, 1000000n);
            clockCalls++;
            if (mode === 'clockFailure') return 29;
            new DataView(instance.exports.memory.buffer).setBigUint64(pointer, 1234567890n, true);
            return 0;
        };
    }
    const module = await WebAssembly.compile(fs.readFileSync(file));
    instance = await WebAssembly.instantiate(module, {
        wasi_snapshot_preview1: wasiImports,
        host: {
            value(key) {
                calls.push(['value', key]);
                assert.ok(key === 1 || key === 2);
                return key === 1 ? 9 : 2;
            },
            finish(value) { calls.push(['finish', value]); },
        },
    });
    if (mode === 'clockFailure') {
        assert.throws(() => wasi.start(instance), WebAssembly.RuntimeError);
        assert.equal(clockCalls, 1);
        assert.equal(entropyCalls, 2);
        console.log('clock failure trapped');
        return;
    }
    assert.equal(wasi.start(instance), 0);
    if (mode === 'platform') {
        assert.equal(entropyCalls, 2);
        assert.equal(clockCalls, 1);
    }
    if (mode === 'host') {
        assert.deepEqual(calls, [['value', 1], ['value', 2], ['finish', 7]]);
        console.log('host=7');
    } else {
        assert.deepEqual(calls, []);
    }
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
