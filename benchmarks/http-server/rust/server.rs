use std::convert::Infallible;
use std::net::SocketAddr;

use http_body_util::Full;
use hyper::body::Bytes;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde::Serialize;
use tokio::net::TcpListener;

#[derive(Serialize)]
struct User {
    id: i32,
    name: String,
    email: String,
    created: i64,
}

async fn handle(req: Request<hyper::body::Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    let path = req.uri().path();
    if req.method() == hyper::Method::GET && path.starts_with("/users/") {
        let id_str = &path[7..];
        if let Ok(id) = id_str.parse::<i32>() {
            let user = User {
                id,
                name: format!("User {id_str}"),
                email: format!("user{id_str}@example.com"),
                created: 1_737_000_000,
            };
            let body = serde_json::to_vec(&user).unwrap();
            return Ok(Response::builder()
                .header("content-type", "application/json")
                .body(Full::new(Bytes::from(body)))
                .unwrap());
        }
    }
    Ok(Response::builder()
        .status(StatusCode::NOT_FOUND)
        .body(Full::new(Bytes::new()))
        .unwrap())
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let addr: SocketAddr = "127.0.0.1:8080".parse().unwrap();
    let listener = TcpListener::bind(addr).await.unwrap();
    eprintln!("listening on {addr}");

    loop {
        let (stream, _) = listener.accept().await.unwrap();
        let io = TokioIo::new(stream);
        tokio::spawn(async move {
            let _ = http1::Builder::new()
                .serve_connection(io, service_fn(handle))
                .await;
        });
    }
}
