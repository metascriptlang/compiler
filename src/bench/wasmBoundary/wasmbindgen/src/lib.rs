use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn add(a: i32, b: i32) -> i32 {
    a.wrapping_add(b)
}

#[wasm_bindgen]
pub fn add64(a: i64, b: i64) -> i64 {
    a.wrapping_add(b)
}

#[wasm_bindgen(js_name = strLen)]
pub fn str_len(s: &str) -> u32 {
    s.len() as u32
}

#[wasm_bindgen]
pub fn echo(s: String) -> String {
    s
}

#[wasm_bindgen]
#[derive(Clone, Copy)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[wasm_bindgen]
impl Point {
    #[wasm_bindgen(constructor)]
    pub fn new(x: f64, y: f64) -> Point {
        Point { x, y }
    }
}

#[wasm_bindgen]
pub fn mid(p: Point) -> Point {
    Point { x: p.x / 2.0, y: p.y / 2.0 }
}

#[wasm_bindgen(js_name = sumVec)]
pub fn sum_vec(xs: Vec<f32>) -> f32 {
    xs.iter().sum()
}

#[wasm_bindgen(js_name = sumSpan)]
pub fn sum_span(xs: &[f32]) -> f32 {
    xs.iter().sum()
}

#[wasm_bindgen(js_name = makeVec)]
pub fn make_vec(n: u32) -> Vec<f32> {
    (0..n).map(|i| i as f32 + 0.5).collect()
}

#[wasm_bindgen(js_name = scaleSpan)]
pub fn scale_span(xs: &mut [f32], k: f32) {
    for x in xs.iter_mut() {
        *x *= k;
    }
}

#[wasm_bindgen]
pub struct FBuf {
    v: Vec<f32>,
}

#[wasm_bindgen]
impl FBuf {
    #[wasm_bindgen(constructor)]
    pub fn new(n: u32) -> FBuf {
        FBuf { v: (0..n).map(|i| i as f32 * 0.25).collect() }
    }

    pub fn scale(&mut self, k: f32) {
        for x in self.v.iter_mut() {
            *x *= k;
        }
    }
}

#[wasm_bindgen]
pub fn each(n: i32, cb: &js_sys::Function) -> i32 {
    let mut s: i32 = 0;
    for i in 0..n {
        let r = cb.call1(&JsValue::NULL, &JsValue::from(i)).unwrap();
        s = s.wrapping_add(r.as_f64().unwrap() as i32);
    }
    s
}

#[wasm_bindgen]
pub fn primes(n: u32) -> u32 {
    let n = n as usize;
    let mut sieve: Vec<bool> = Vec::new();
    for _ in 0..n {
        sieve.push(true);
    }
    let mut count = 0;
    for i in 2..n {
        if sieve[i] {
            count += 1;
            if i <= n / i {
                let mut j = i * i;
                while j < n {
                    sieve[j] = false;
                    j += i;
                }
            }
        }
    }
    count
}
