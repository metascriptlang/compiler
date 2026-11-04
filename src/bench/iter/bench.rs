// The rows of bench.ms written as a Rust author would: slice iterators and adapter chains, iter::from_fn for a
// generator since stable Rust has none. bench() repeats the shared harness's rounds and output line.

use std::hint::black_box;
use std::time::Instant;

const SIZE: usize = 65536;
const SIDE: usize = 256;
const MIN_ROUND_MS: f64 = 250.0;

fn round(op: &mut impl FnMut()) -> f64 {
    let mut calls: u64 = 1;
    loop {
        let start = Instant::now();
        for _ in 0..calls {
            op();
        }
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        if elapsed >= MIN_ROUND_MS {
            return elapsed / calls as f64;
        }
        calls = if elapsed < 1.0 { calls * 16 } else { (calls as f64 * (MIN_ROUND_MS * 1.2 / elapsed)).ceil() as u64 };
    }
}

fn fixed(value: f64, digits: i32) -> f64 {
    let scale = 10f64.powi(digits);
    (value * scale).round() / scale
}

fn bench(name: &str, mut op: impl FnMut()) {
    let mut rates: Vec<f64> = (0..3).map(|_| round(&mut op) * 1000.0).collect();
    rates.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = rates[1];
    let spread = (rates[2] - rates[0]) / median * 100.0;
    println!("{:<28}{:<18}spread {}%", name, format!("{} us/op", fixed(median, 3)), fixed(spread, 1));
}

fn next_pass(pass: &mut usize) -> usize {
    *pass += 1;
    *pass
}

fn filled(count: usize, step: usize, offset: usize) -> Vec<i32> {
    (0..count).map(|i| ((i * step + offset) % 1000) as i32).collect()
}

fn bump(values: &mut [i32], pass: &mut usize) {
    let at = next_pass(pass) % values.len();
    values[at] += 1;
}

#[allow(clippy::needless_range_loop)]
fn indexed_sum(values: &[i32]) -> i32 {
    let mut total = 0;
    for i in 0..values.len() {
        total += values[i];
    }
    total
}

fn for_of_sum(values: &[i32]) -> i32 {
    let mut total = 0;
    for &x in values {
        total += x;
    }
    total
}

fn values_sum(values: &[i32]) -> i32 {
    let mut total = 0;
    for x in values.iter().copied() {
        total += x;
    }
    total
}

#[allow(clippy::needless_range_loop)]
fn keys_sum(values: &[i32]) -> i32 {
    let mut total = 0;
    for i in 0..values.len() {
        total += values[i];
    }
    total
}

fn entries_sum(values: &[i32]) -> i32 {
    let mut total = 0;
    for (i, &x) in values.iter().enumerate() {
        total += x + (i as i32 & 1);
    }
    total
}

fn grid_sum(rows: &[Vec<i32>]) -> i32 {
    let mut total = 0;
    for row in rows {
        for &x in row {
            total += x;
        }
    }
    total
}

fn up_to(limit: i32) -> impl Iterator<Item = i32> {
    let mut i = 0;
    std::iter::from_fn(move || {
        if i < limit {
            i += 1;
            Some(i - 1)
        } else {
            None
        }
    })
}

fn relay(limit: i32) -> impl Iterator<Item = i32> {
    let mut source = up_to(limit);
    std::iter::from_fn(move || source.next())
}

fn generator_sum(salt: i32) -> i32 {
    let mut total = 0;
    for x in up_to(SIZE as i32) {
        total += (x ^ salt) & 1023;
    }
    total
}

fn nested_generator_sum(salt: i32) -> i32 {
    let mut total = 0;
    for x in relay(SIZE as i32) {
        total += (x ^ salt) & 1023;
    }
    total
}

fn range_sum(salt: i32) -> f64 {
    (salt..salt + SIZE as i32).map(f64::from).sum()
}

fn chain_for_of_sum(values: &[i32]) -> i32 {
    let chain = values.iter().map(|&x| x * 2).filter(|&x| x % 3 != 0).take(SIZE / 2);
    let mut total = 0;
    for x in chain {
        total += x;
    }
    total
}

fn chain_reduce_sum(values: &[i32]) -> i32 {
    values.iter().map(|&x| x * 2).filter(|&x| x % 3 != 0).take(SIZE / 2).sum()
}

fn make_chain(values: &[i32]) -> impl Iterator<Item = i32> + '_ {
    values.iter().map(|&x| x * 2).filter(|&x| x % 3 != 0).take(SIZE / 2)
}

fn stored_chain_sum(values: &[i32]) -> i32 {
    let mut total = 0;
    for x in make_chain(values) {
        total += x;
    }
    total
}

fn to_array_sum(values: &[i32]) -> i32 {
    let out: Vec<i32> = values.iter().map(|&x| x * 2).collect();
    out.iter().sum()
}

fn zip_sum(left: &[i32], right: &[i32]) -> i32 {
    left.iter().zip(right).map(|(&x, &y)| (x * y) & 1023).sum()
}

fn eager_sum(values: &[i32]) -> i32 {
    let mapped: Vec<i32> = values.iter().map(|&x| x * 2).collect();
    let kept: Vec<i32> = mapped.into_iter().filter(|&x| x % 3 != 0).collect();
    kept.iter().sum()
}

fn main() {
    let mut sink: f64 = 0.0;
    let mut pass: usize = 0;
    let mut arr = filled(SIZE, 7, 3);
    let other = filled(SIZE, 13, 5);
    let mut vec = arr.clone();
    let mut grid: Vec<Vec<i32>> = (0..SIDE).map(|r| filled(SIDE, 7, r)).collect();

    bench("indexed for int32[]", || {
        sink += black_box(indexed_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("for-of int32[]", || {
        sink += black_box(for_of_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("for-of Vec<int32>", || {
        sink += black_box(for_of_sum(&vec)) as f64;
        bump(&mut vec, &mut pass);
    });
    bench("for-of values()", || {
        sink += black_box(values_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("for-of keys()", || {
        sink += black_box(keys_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("for-of entries()", || {
        sink += black_box(entries_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("for-of nested 256x256", || {
        sink += black_box(grid_sum(&grid)) as f64;
        let row = next_pass(&mut pass) % SIDE;
        bump(&mut grid[row], &mut pass);
    });
    bench("generator", || sink += black_box(generator_sum(next_pass(&mut pass) as i32)) as f64);
    bench("nested generator", || sink += black_box(nested_generator_sum(next_pass(&mut pass) as i32)) as f64);
    bench("Iterator.range float64", || sink += black_box(range_sum(next_pass(&mut pass) as i32)));
    bench("chain for-of", || {
        sink += black_box(chain_for_of_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("chain reduce", || {
        sink += black_box(chain_reduce_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("chain stored in a function", || {
        sink += black_box(stored_chain_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("map toArray", || {
        sink += black_box(to_array_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("zip product", || {
        sink += black_box(zip_sum(&arr, &other)) as f64;
        bump(&mut arr, &mut pass);
    });
    bench("eager map filter reduce", || {
        sink += black_box(eager_sum(&arr)) as f64;
        bump(&mut arr, &mut pass);
    });

    if sink < 0.0 {
        println!("unreachable {}", sink);
    }
}
