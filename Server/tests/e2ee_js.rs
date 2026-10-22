//! Runs the cross-language E2EE tests (`tests/e2ee/crypto.test.mjs`) with Node:
//! vectors from the Swift encoder against an independent Web Crypto encoder and
//! the browser decoder as served. Skipped when `node` is missing, unless
//! `XNOTCH_REQUIRE_NODE=1` (set it in CI).

use std::process::Command;

#[test]
fn browser_decoder_matches_the_swift_encoder() {
    let dir = env!("CARGO_MANIFEST_DIR");
    let output = match Command::new("node").args(["--test", "tests/e2ee/crypto.test.mjs"]).current_dir(dir).output() {
        Ok(output) => output,
        Err(e) if std::env::var("XNOTCH_REQUIRE_NODE").as_deref() != Ok("1") => {
            eprintln!("skipping the JavaScript E2EE tests: cannot run node ({e})");
            return;
        }
        Err(e) => panic!("cannot run node: {e}"),
    };
    let report = format!("{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    assert!(output.status.success(), "node tests failed:\n{report}");
    assert!(report.contains("# fail 0") || report.contains("ℹ fail 0"), "{report}");
}
