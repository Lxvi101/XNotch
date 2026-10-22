//! Server-rendered HTML pages. Everything is self-contained: inline CSS, inline
//! SVG icons and small inline scripts (a countdown, and the decryptor of
//! encrypted drops), all allowed by a per-response nonce. No third-party code.

use std::fmt::Write;

use chrono::{DateTime, Utc};

use crate::model::DropMeta;
use crate::{e2ee, names};

/// Images larger than this are not previewed inline on the drop page.
const PREVIEW_MAX_BYTES: u64 = 25 * 1000 * 1000;

const CSS: &str = r#"
:root{--bg:#0a0a0a;--card:#1c1c1e;--raised:#2c2c2e;--text:#f5f5f7;--muted:#8e8e93;--faint:#636366;--line:rgba(255,255,255,.06);--blue:#0a84ff}
*{box-sizing:border-box;margin:0;padding:0}
html{background:var(--bg);color-scheme:dark}
body{min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
body::before{content:"";position:fixed;inset:0;z-index:-1;pointer-events:none;background-image:radial-gradient(rgba(255,255,255,.09) 1px,transparent 1.3px);background-size:22px 22px;-webkit-mask-image:radial-gradient(ellipse 90% 70% at 50% 0%,#000 25%,transparent 75%);mask-image:radial-gradient(ellipse 90% 70% at 50% 0%,#000 25%,transparent 75%)}
main{flex:1;width:100%;max-width:680px;margin:0 auto;padding:clamp(56px,13vh,128px) 20px 32px}
h1{font-size:clamp(34px,7.5vw,54px);line-height:1.06;font-weight:700;letter-spacing:-.028em;overflow-wrap:anywhere}
.sub{margin-top:12px;color:var(--muted);font-size:17px;letter-spacing:-.01em}
.files{list-style:none;margin-top:36px;display:grid;gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;overflow:hidden}
.preview{display:block;background:#000;border-bottom:1px solid var(--line)}
.preview img{display:block;width:100%;max-height:440px;object-fit:contain}
.row{display:flex;align-items:center;gap:14px;padding:14px 14px 14px 16px}
.icon{flex:none;width:42px;height:42px;border-radius:11px;display:grid;place-items:center}
.icon svg{width:22px;height:22px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.k-image{background:rgba(94,92,230,.18);color:#8e8cff}
.k-video{background:rgba(255,55,95,.16);color:#ff6482}
.k-audio{background:rgba(255,159,10,.16);color:#ffb340}
.k-pdf{background:rgba(255,69,58,.16);color:#ff6961}
.k-archive{background:rgba(172,142,104,.18);color:#c9a97f}
.k-code{background:rgba(48,209,88,.15);color:#4cd964}
.k-doc{background:rgba(10,132,255,.16);color:#409cff}
.k-file{background:var(--raised);color:#aeaeb2}
.info{flex:1;min-width:0}
.name{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.size{margin-top:2px;color:var(--muted);font-size:13px}
.pill{flex:none;padding:8px 16px;border-radius:999px;background:var(--blue);color:#fff;font-size:14px;font-weight:600;text-decoration:none;transition:background .15s}
.pill:hover{background:#409cff}
.pill:focus-visible,.preview:focus-visible{outline:2px solid #fff;outline-offset:2px}
.lock{margin-top:36px;display:flex;gap:10px}
.lock input{flex:1;min-width:0;padding:12px 16px;border-radius:999px;border:1px solid var(--line);background:var(--card);color:var(--text);font:inherit;font-size:16px}
.lock input:focus{outline:2px solid var(--blue);outline-offset:1px;border-color:transparent}
.lock .pill{border:0;font:inherit;font-weight:600;cursor:pointer}
.error{margin-top:12px;color:#ff6961;font-size:14px}
.error-text{color:#ff6961}
button.pill{border:0;font:inherit;font-size:14px;font-weight:600;cursor:pointer}
button.pill:disabled{opacity:.5;cursor:default}
.note{margin-top:28px;display:flex;gap:8px;align-items:flex-start;color:var(--muted);font-size:13px}
.note svg{flex:none;width:16px;height:16px;margin-top:1px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
[hidden]{display:none!important}
.empty{margin-top:36px;padding:28px;border:1px dashed rgba(255,255,255,.12);border-radius:18px;color:var(--muted);text-align:center}
footer{padding:28px 20px calc(36px + env(safe-area-inset-bottom));text-align:center;color:var(--faint);font-size:13px}
@media (max-width:440px){.row{gap:12px;padding:12px}.pill{padding:7px 13px}.sub{font-size:16px}}
"#;

/// Counts down the "Expires in" label so it stays honest on long-lived tabs.
const COUNTDOWN_JS: &str = r#"(function(){var e=document.getElementById("exp");if(!e)return;var t=+e.getAttribute("data-expires")*1000;function p(n,u){return n+" "+u+(n===1?"":"s")}function h(s){if(s<60)return"less than a minute";if(s<3600)return p(Math.floor(s/60),"minute");if(s<172800)return p(Math.floor(s/3600),"hour");return p(Math.floor(s/86400),"day")}function f(){var s=Math.floor((t-Date.now())/1000);if(s<=0){e.textContent="Expired";return}e.textContent="Expires in "+h(s);setTimeout(f,s<3600?5000:60000)}f()})();"#;

/// Keeps the URL fragment (an encrypted drop's key) when the password form posts:
/// the browser carries the action's fragment over to the redirect back to the page.
const KEEP_FRAGMENT_JS: &str = r#"(function(){var f=document.querySelector("form.lock");if(f&&location.hash)f.setAttribute("action",f.getAttribute("action")+location.hash)})();"#;

const LOCK_ICON: &str = r#"<rect x="5" y="11" width="14" height="10" rx="2.5"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>"#;

/// Escapes text for HTML element content and quoted attribute values.
pub fn escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// Human file size with decimal units, like Finder: `512 bytes`, `12.4 MB`.
pub fn format_size(bytes: u64) -> String {
    if bytes < 1000 {
        return format!("{bytes} {}", if bytes == 1 { "byte" } else { "bytes" });
    }
    let units = ["KB", "MB", "GB", "TB", "PB"];
    let mut value = bytes as f64 / 1000.0;
    let mut unit = 0;
    while value >= 999.95 && unit < units.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    let text = if value < 100.0 { format!("{value:.1}") } else { format!("{value:.0}") };
    format!("{} {}", text.trim_end_matches(".0"), units[unit])
}

fn plural(n: u64, unit: &str) -> String {
    format!("{n} {unit}{}", if n == 1 { "" } else { "s" })
}

/// Remaining time as shown in the subtitle; mirrors `COUNTDOWN_JS`.
pub fn format_remaining(seconds: i64) -> String {
    let s = seconds.max(0) as u64;
    match s {
        0..60 => "less than a minute".into(),
        60..3600 => plural(s / 60, "minute"),
        3600..172_800 => plural(s / 3600, "hour"),
        _ => plural(s / 86_400, "day"),
    }
}

fn kind(content_type: &str, name: &str) -> &'static str {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    match content_type.split_once('/') {
        Some(("image", _)) => "image",
        Some(("video", _)) => "video",
        Some(("audio", _)) => "audio",
        _ if content_type == "application/pdf" => "pdf",
        _ if matches!(
            ext.as_str(),
            "zip" | "7z" | "rar" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "zst" | "dmg" | "pkg" | "iso"
        ) =>
        {
            "archive"
        }
        Some(("text", _)) => "code",
        _ if matches!(content_type, "application/json" | "application/xml" | "application/javascript") => "code",
        _ if matches!(
            ext.as_str(),
            "doc" | "docx" | "pages" | "rtf" | "odt" | "xls" | "xlsx" | "numbers" | "csv" | "ppt" | "pptx" | "key"
        ) =>
        {
            "doc"
        }
        _ => "file",
    }
}

fn icon(kind: &str) -> &'static str {
    match kind {
        "image" => {
            r#"<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="1.6"/><path d="m21 15.5-4.5-4.5L8 19.5"/>"#
        }
        "video" => r#"<rect x="2.5" y="5.5" width="13.5" height="13" rx="3"/><path d="m16 10.5 5.5-3.5v10L16 13.5"/>"#,
        "audio" => {
            r#"<path d="M9 17.5V6l11-2v11.5"/><circle cx="6.5" cy="17.5" r="2.5"/><circle cx="17.5" cy="15.5" r="2.5"/>"#
        }
        "archive" => {
            r#"<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>"#
        }
        "code" => r#"<path d="m8.5 8-4 4 4 4M15.5 8l4 4-4 4M13.5 5.5l-3 13"/>"#,
        "pdf" | "doc" => {
            r#"<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 13h6M9 17h4"/>"#
        }
        _ => r#"<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>"#,
    }
}

/// Wraps page content. `is_drop` adds the countdown script and the "Shared with"
/// footer; `extra_js` is another inline script for the page.
fn layout(title: &str, site_name: &str, nonce: &str, body: &str, is_drop: bool, extra_js: &[&str]) -> String {
    let footer = if is_drop { "Shared with " } else { "" };
    let mut script = String::new();
    if is_drop {
        let _ = write!(script, r#"<script nonce="{nonce}">{COUNTDOWN_JS}</script>"#);
    }
    if !extra_js.is_empty() {
        let _ = write!(script, r#"<script nonce="{nonce}">{}</script>"#, extra_js.concat());
    }
    format!(
        r##"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0a0a0a">
<title>{title} · {site}</title>
<style nonce="{nonce}">{CSS}</style>
</head>
<body>
<main>
{body}
</main>
<footer>{footer}{site}</footer>
{script}
</body>
</html>
"##,
        title = escape(title),
        site = escape(site_name),
    )
}

/// The public page for one drop.
pub fn drop_page(meta: &DropMeta, site_name: &str, now: DateTime<Utc>, nonce: &str) -> String {
    let count = meta.files.len() as u64;
    let title = match meta.title.as_deref() {
        Some(t) => t.to_owned(),
        None if count == 0 => "Empty drop".to_owned(),
        None => plural(count, "file"),
    };
    let remaining = format_remaining((meta.expires_at - now).num_seconds());
    let details = if count == 0 {
        "No files yet".to_owned()
    } else {
        format!("{} · {}", plural(count, "file"), format_size(meta.total_size()))
    };

    let mut body = format!(
        r#"<h1>{}</h1>
<p class="sub"><span id="exp" data-expires="{}">Expires in {remaining}</span> · {details}</p>
"#,
        escape(&title),
        meta.expires_at.timestamp(),
    );

    if meta.files.is_empty() {
        body.push_str(r#"<div class="empty">Files will appear here once they finish uploading.</div>"#);
    } else {
        body.push_str("<ul class=\"files\">\n");
        for file in &meta.files {
            let href = format!("/{}/{}", meta.id, names::encode_segment(&file.name));
            let kind = kind(&file.content_type, &file.name);
            let name = escape(&file.name);
            body.push_str("<li class=\"card\">");
            if kind == "image" && names::is_inline_safe(&file.content_type) && file.size <= PREVIEW_MAX_BYTES {
                let _ = write!(
                    body,
                    r#"<a class="preview" href="{href}?inline=1" aria-label="Open {name}"><img src="{href}?inline=1" alt="" loading="lazy" decoding="async"></a>"#
                );
            }
            let _ = writeln!(
                body,
                r#"<div class="row"><div class="icon k-{kind}"><svg viewBox="0 0 24 24" aria-hidden="true">{icon}</svg></div><div class="info"><div class="name" title="{name}">{name}</div><div class="size">{size}</div></div><a class="pill" href="{href}" download>Download</a></div></li>"#,
                icon = icon(kind),
                size = format_size(file.size),
            );
        }
        body.push_str("</ul>");
    }

    layout(&title, site_name, nonce, &body, true, &[])
}

/// The page of an end-to-end encrypted drop. The server knows neither the
/// title nor the file names, so the page is a shell: its script decrypts the
/// manifest with the key in the URL fragment and fills it in.
pub fn encrypted_drop_page(meta: &DropMeta, site_name: &str, now: DateTime<Utc>, nonce: &str) -> String {
    let remaining = format_remaining((meta.expires_at - now).num_seconds());
    let mut glyphs = String::new();
    for kind in ["image", "video", "audio", "pdf", "archive", "code", "doc", "file"] {
        let _ = write!(
            glyphs,
            r#"<template id="glyph-{kind}"><svg viewBox="0 0 24 24" aria-hidden="true">{}</svg></template>"#,
            icon(kind)
        );
    }
    let body = format!(
        r#"<div id="e2ee" data-drop="{id}">
<h1 id="title">Encrypted files</h1>
<p class="sub"><span id="exp" data-expires="{expires}">Expires in {remaining}</span><span id="details"> · Decrypting…</span></p>
<noscript><div class="empty">These files are end-to-end encrypted. Turn on JavaScript to decrypt them in this browser.</div></noscript>
<ul class="files" id="files" aria-live="polite"></ul>
<div class="empty" id="notice" role="alert" hidden></div>
<p class="note"><svg viewBox="0 0 24 24" aria-hidden="true">{LOCK_ICON}</svg><span>End-to-end encrypted. Files are decrypted in this browser with the key at the end of the link, which is never sent to the server.</span></p>
</div>
{glyphs}"#,
        id = escape(&meta.id),
        expires = meta.expires_at.timestamp(),
    );
    layout("Encrypted files", site_name, nonce, &body, true, &[e2ee::CORE_JS, e2ee::PAGE_JS])
}

/// Asks for the password of a protected drop. Shows nothing about the drop
/// except how long it lasts: even its title waits for the password.
pub fn locked_page(meta: &DropMeta, site_name: &str, wrong: bool, nonce: &str) -> String {
    let error = if wrong { r#"<p class="error" role="alert">That password isn't right.</p>"# } else { "" };
    let body = format!(
        r#"<h1>Password required</h1>
<p class="sub">Enter the password to see these files. <span id="exp" data-expires="{expires}"></span></p>
<form class="lock" method="post" action="/{id}">
<input type="password" name="password" aria-label="Password" placeholder="Password" autocomplete="current-password" required autofocus>
<button class="pill" type="submit">Unlock</button>
</form>
{error}"#,
        expires = meta.expires_at.timestamp(),
        id = meta.id,
    );
    layout("Password required", site_name, nonce, &body, true, &[KEEP_FRAGMENT_JS])
}

pub fn not_found_page(site_name: &str, nonce: &str) -> String {
    let body = r#"<h1>Not found</h1>
<p class="sub">This link has expired or never existed.</p>"#;
    layout("Not found", site_name, nonce, body, false, &[])
}

pub fn home_page(site_name: &str, nonce: &str) -> String {
    let body = format!(
        r#"<h1>{}</h1>
<p class="sub">Files shared from XNotch appear at their own short links.</p>"#,
        escape(site_name)
    );
    layout(site_name, site_name, nonce, &body, false, &[])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::FileMeta;

    #[test]
    fn escapes_html() {
        assert_eq!(escape(r#"<a href="x">'&'</a>"#), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    }

    #[test]
    fn formats_sizes() {
        assert_eq!(format_size(0), "0 bytes");
        assert_eq!(format_size(1), "1 byte");
        assert_eq!(format_size(999), "999 bytes");
        assert_eq!(format_size(1000), "1 KB");
        assert_eq!(format_size(12_400_000), "12.4 MB");
        assert_eq!(format_size(124_000_000), "124 MB");
        assert_eq!(format_size(999_990_000), "1 GB");
        assert_eq!(format_size(5 * 1024 * 1024 * 1024), "5.4 GB");
    }

    #[test]
    fn formats_remaining_time() {
        assert_eq!(format_remaining(-10), "less than a minute");
        assert_eq!(format_remaining(59), "less than a minute");
        assert_eq!(format_remaining(61), "1 minute");
        assert_eq!(format_remaining(86_399), "23 hours");
        assert_eq!(format_remaining(3 * 86_400), "3 days");
    }

    #[test]
    fn page_escapes_user_text() {
        let now = DateTime::parse_from_rfc3339("2026-10-13T10:00:00Z").unwrap().with_timezone(&Utc);
        let mut meta = DropMeta::new("abcdefgh".into(), Some("<script>alert(1)</script>".into()), now, 3600);
        meta.upsert_file(FileMeta { name: "\"><img src=x>.png".into(), size: 10, content_type: "image/png".into() });
        let html = drop_page(&meta, "Site & <Co>", now, "n0nce");
        assert!(!html.contains("<script>alert"));
        assert!(!html.contains("<img src=x>"));
        assert!(html.contains("Shared with Site &amp; &lt;Co&gt;"));
        assert!(html.contains("/abcdefgh/%22%3E%3Cimg%20src%3Dx%3E.png?inline=1"));
        assert!(html.contains(">Expires in 1 hour</span> · 1 file · 10 bytes"));
    }

    #[test]
    fn encrypted_page_reveals_nothing_the_manifest_hides() {
        let now = DateTime::parse_from_rfc3339("2026-10-13T10:00:00Z").unwrap().with_timezone(&Utc);
        let mut meta = DropMeta::new("abcdefgh".into(), None, now, 3600);
        meta.e2ee = Some(1);
        meta.upsert_file(FileMeta {
            name: "0123456789abcdef0123456789abcdef".into(),
            size: 12_345,
            content_type: "application/octet-stream".into(),
        });
        let html = encrypted_drop_page(&meta, "Site", now, "n0nce");
        assert!(html.contains(r#"<div id="e2ee" data-drop="abcdefgh">"#));
        assert!(!html.contains("0123456789abcdef0123456789abcdef"), "object names stay off the page");
        assert!(!html.contains("12,345") && !html.contains("12.3 KB"), "sizes come from the manifest");
        assert!(html.contains("var XNE = "));
        assert_eq!(html.matches(r#"<script nonce="n0nce">"#).count(), 2);
        assert!(!html.contains("<script src"));
    }

    #[test]
    fn locked_page_keeps_the_fragment() {
        let meta = DropMeta::new("abcdefgh".into(), None, Utc::now(), 3600);
        let html = locked_page(&meta, "Site", false, "n0nce");
        assert!(html.contains(KEEP_FRAGMENT_JS));
        assert!(html.contains(r#"action="/abcdefgh""#));
    }
}
