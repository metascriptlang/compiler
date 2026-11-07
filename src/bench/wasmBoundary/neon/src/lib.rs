use neon::prelude::*;
use neon::types::buffer::TypedArray;
use neon::types::JsBigInt;

fn add(mut cx: FunctionContext) -> JsResult<JsNumber> {
    let a = cx.argument::<JsNumber>(0)?.value(&mut cx) as i32;
    let b = cx.argument::<JsNumber>(1)?.value(&mut cx) as i32;
    Ok(cx.number(a.wrapping_add(b)))
}

fn add64(mut cx: FunctionContext) -> JsResult<JsBigInt> {
    let a = cx.argument::<JsBigInt>(0)?.to_i64(&mut cx).or_throw(&mut cx)?;
    let b = cx.argument::<JsBigInt>(1)?.to_i64(&mut cx).or_throw(&mut cx)?;
    Ok(JsBigInt::from_i64(&mut cx, a.wrapping_add(b)))
}

fn str_len(mut cx: FunctionContext) -> JsResult<JsNumber> {
    let s = cx.argument::<JsString>(0)?.value(&mut cx);
    Ok(cx.number(s.len() as f64))
}

fn echo(mut cx: FunctionContext) -> JsResult<JsString> {
    let s = cx.argument::<JsString>(0)?.value(&mut cx);
    Ok(cx.string(s))
}

fn mid(mut cx: FunctionContext) -> JsResult<JsObject> {
    let p = cx.argument::<JsObject>(0)?;
    let x = p.get::<JsNumber, _, _>(&mut cx, "x")?.value(&mut cx);
    let y = p.get::<JsNumber, _, _>(&mut cx, "y")?.value(&mut cx);
    let o = cx.empty_object();
    let vx = cx.number(x / 2.0);
    let vy = cx.number(y / 2.0);
    o.set(&mut cx, "x", vx)?;
    o.set(&mut cx, "y", vy)?;
    Ok(o)
}

fn sum_vec(mut cx: FunctionContext) -> JsResult<JsNumber> {
    let arr = cx.argument::<JsArray>(0)?.to_vec(&mut cx)?;
    let mut s: f32 = 0.0;
    for v in arr {
        s += v.downcast_or_throw::<JsNumber, _>(&mut cx)?.value(&mut cx) as f32;
    }
    Ok(cx.number(s))
}

fn sum_span(mut cx: FunctionContext) -> JsResult<JsNumber> {
    let a = cx.argument::<JsTypedArray<f32>>(0)?;
    let s: f32 = a.as_slice(&cx).iter().sum();
    Ok(cx.number(s))
}

fn make_vec(mut cx: FunctionContext) -> JsResult<JsTypedArray<f32>> {
    let n = cx.argument::<JsNumber>(0)?.value(&mut cx) as usize;
    let v: Vec<f32> = (0..n).map(|i| i as f32 + 0.5).collect();
    JsTypedArray::from_slice(&mut cx, &v)
}

fn scale_span(mut cx: FunctionContext) -> JsResult<JsUndefined> {
    let mut a = cx.argument::<JsTypedArray<f32>>(0)?;
    let k = cx.argument::<JsNumber>(1)?.value(&mut cx) as f32;
    for x in a.as_mut_slice(&mut cx).iter_mut() {
        *x *= k;
    }
    Ok(cx.undefined())
}

fn each(mut cx: FunctionContext) -> JsResult<JsNumber> {
    let n = cx.argument::<JsNumber>(0)?.value(&mut cx) as i32;
    let cb = cx.argument::<JsFunction>(1)?;
    let mut s: i32 = 0;
    for i in 0..n {
        let r: Handle<JsNumber> = cb.call_with(&cx).arg(cx.number(i)).apply(&mut cx)?;
        s = s.wrapping_add(r.value(&mut cx) as i32);
    }
    Ok(cx.number(s))
}

fn primes(mut cx: FunctionContext) -> JsResult<JsNumber> {
    let n = cx.argument::<JsNumber>(0)?.value(&mut cx) as usize;
    let mut sieve: Vec<bool> = Vec::new();
    for _ in 0..n { sieve.push(true); }
    let mut count = 0;
    for i in 2..n {
        if sieve[i] {
            count += 1;
            if i <= n / i {
                let mut j = i * i;
                while j < n { sieve[j] = false; j += i; }
            }
        }
    }
    Ok(cx.number(count as f64))
}

#[neon::main]
fn main(mut cx: ModuleContext) -> NeonResult<()> {
    cx.export_function("add", add)?;
    cx.export_function("add64", add64)?;
    cx.export_function("strLen", str_len)?;
    cx.export_function("echo", echo)?;
    cx.export_function("mid", mid)?;
    cx.export_function("sumVec", sum_vec)?;
    cx.export_function("sumSpan", sum_span)?;
    cx.export_function("makeVec", make_vec)?;
    cx.export_function("scaleSpan", scale_span)?;
    cx.export_function("each", each)?;
    cx.export_function("primes", primes)?;
    Ok(())
}
