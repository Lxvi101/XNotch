use std::io::{IsTerminal, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use tracing_subscriber::EnvFilter;
use xnotch_cloud::config::{Config, StorageConfig};
use xnotch_cloud::storage::Storage;
use xnotch_cloud::{AppState, app, spawn_sweeper};

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("--healthcheck") => return healthcheck(),
        Some("--version" | "-V") => {
            println!("xnotch-cloud {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Some(other) => {
            eprintln!("unknown argument `{other}`; configure the server with environment variables (see README)");
            return ExitCode::FAILURE;
        }
        None => {}
    }

    init_tracing();
    let config = match Config::from_env() {
        Ok(config) => config,
        Err(e) => {
            tracing::error!("configuration error: {e}");
            return ExitCode::FAILURE;
        }
    };

    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
    match runtime.block_on(serve(config)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!("{e}");
            ExitCode::FAILURE
        }
    }
}

async fn serve(config: Config) -> Result<(), String> {
    let storage = Storage::from_config(&config.storage)?;
    match &config.storage {
        StorageConfig::Local { data_dir } => tracing::info!(data_dir = %data_dir.display(), "using local storage"),
        StorageConfig::S3 { bucket, endpoint, .. } => {
            tracing::info!(bucket, endpoint = endpoint.as_deref().unwrap_or("aws"), "using S3 storage")
        }
    }

    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    let state = Arc::new(AppState::new(config, storage));
    if state.relay.enabled() {
        let rooms = state.relay.load(&state.storage).await.map_err(|e| format!("cannot load relay rooms: {e}"))?;
        tracing::info!(rooms, "relay enabled");
    } else {
        tracing::info!("relay disabled");
    }
    let sweeper = spawn_sweeper(state.clone());

    let listener = tokio::net::TcpListener::bind(addr).await.map_err(|e| format!("cannot bind {addr}: {e}"))?;
    tracing::info!(%addr, public_url = %state.config.public_url, version = env!("CARGO_PKG_VERSION"), "listening");

    axum::serve(listener, app(state).into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| format!("server error: {e}"))?;
    sweeper.abort();
    tracing::info!("stopped");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received, draining connections");
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let builder =
        tracing_subscriber::fmt().with_env_filter(filter).with_target(false).with_ansi(std::io::stdout().is_terminal());
    if std::env::var("LOG_FORMAT").is_ok_and(|f| f.eq_ignore_ascii_case("json")) {
        builder.json().flatten_event(true).with_span_list(false).init();
    } else {
        builder.init();
    }
}

/// `xnotch-cloud --healthcheck`: a dependency-free probe for Docker's HEALTHCHECK,
/// so the runtime image needs no curl or wget.
fn healthcheck() -> ExitCode {
    let port: u16 = std::env::var("PORT").ok().and_then(|p| p.trim().parse().ok()).unwrap_or(8080);
    let probe = || -> std::io::Result<bool> {
        let addr = SocketAddr::from(([127, 0, 0, 1], port));
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(3))?;
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        stream.write_all(b"GET /healthz HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")?;
        let mut response = String::new();
        stream.take(4096).read_to_string(&mut response)?;
        Ok(response.split_whitespace().nth(1) == Some("200"))
    };
    match probe() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => {
            eprintln!("healthcheck: unexpected response");
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("healthcheck: {e}");
            ExitCode::FAILURE
        }
    }
}
