// The page of an end-to-end encrypted drop: decrypts the manifest with the key from the
// URL fragment, lists the files, and decrypts each download in this browser. Plaintext
// is handed to the user only after the whole file authenticated.
(function () {
  "use strict";

  var root = document.getElementById("e2ee");
  if (!root) return;
  // Above this, a file is only decrypted straight to disk (File System Access API),
  // because the fallback keeps the whole plaintext in memory until it is verified.
  // The server never sets the attribute; the browser tests do, to reach the disk path.
  var MEMORY_LIMIT = Number(root.getAttribute("data-memory-limit")) || 1024 * 1024 * 1024;
  var dropId = root.getAttribute("data-drop");
  var titleEl = document.getElementById("title");
  var detailsEl = document.getElementById("details");
  var listEl = document.getElementById("files");
  var noticeEl = document.getElementById("notice");
  var busy = false;

  function show(message) {
    noticeEl.textContent = message;
    noticeEl.hidden = false;
    listEl.hidden = true;
    detailsEl.textContent = "";
  }

  function plural(n, unit) {
    return n + " " + unit + (n === 1 ? "" : "s");
  }

  // Mirrors `format_size` on the server: decimal units, like Finder.
  function formatSize(bytes) {
    if (bytes < 1000) return bytes + (bytes === 1 ? " byte" : " bytes");
    var units = ["KB", "MB", "GB", "TB", "PB"];
    var value = bytes / 1000;
    var unit = 0;
    while (value >= 999.95 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    var text = value < 100 ? value.toFixed(1) : value.toFixed(0);
    return text.replace(/\.0$/, "") + " " + units[unit];
  }

  function kind(name) {
    var ext = (name.lastIndexOf(".") > 0 ? name.slice(name.lastIndexOf(".") + 1) : "").toLowerCase();
    var groups = {
      image: "png jpg jpeg gif webp avif heic heif tif tiff bmp svg",
      video: "mp4 mov m4v webm mkv avi",
      audio: "mp3 m4a aac wav flac ogg aiff",
      pdf: "pdf",
      archive: "zip 7z rar tar gz tgz bz2 xz zst dmg pkg iso",
      code: "txt md json xml js ts swift rs py c h cpp css html sh yml yaml toml csv log",
      doc: "doc docx pages rtf odt xls xlsx numbers ppt pptx key"
    };
    for (var k in groups) {
      if (ext && (" " + groups[k] + " ").indexOf(" " + ext + " ") >= 0) return k;
    }
    return "file";
  }

  function element(tag, className, text) {
    var el = document.createElement(tag);
    if (className) el.className = className;
    if (text != null) el.textContent = text;
    return el;
  }

  function message(error) {
    switch (error && error.code) {
      case "auth":
        return "This file was changed or damaged after it was shared, so nothing was saved.";
      case "truncated":
      case "trailing":
      case "size":
        return "This file arrived incomplete or altered, so nothing was saved.";
      case "too-large":
        return "This file is too large to decrypt in this browser. Open the link in Chrome or Edge on a computer.";
      case "gone":
        return "This file is no longer available.";
      case "version":
      case "no-crypto":
        return error.message;
      default:
        return "Couldn't download this file. Check your connection and try again.";
    }
  }

  function fail(code) {
    var error = new Error(code);
    error.code = code;
    return error;
  }

  async function fetchObject(path) {
    var response = await fetch(path, { credentials: "same-origin", cache: "no-store", redirect: "error" });
    if (response.status === 404) throw fail("gone");
    if (!response.ok || !response.body) throw fail("network");
    return response;
  }

  async function loadManifest(key) {
    var response;
    try {
      response = await fetch("/" + dropId + "/-/manifest", {
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error"
      });
    } catch (e) {
      throw fail("network");
    }
    if (response.status === 404) throw fail("pending");
    if (!response.ok) throw fail("network");
    var declared = Number(response.headers.get("content-length"));
    if (declared > XNE.MAX_MANIFEST_BYTES) throw fail("manifest");
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > XNE.MAX_MANIFEST_BYTES) throw fail("manifest");
    var plaintext = await XNE.decryptBytes(key, { kind: "manifest", dropId: dropId }, bytes);
    return XNE.parseManifest(plaintext);
  }

  function render(manifest, key) {
    var total = manifest.files.reduce(function (sum, f) {
      return sum + f.size;
    }, 0);
    var count = manifest.files.length;
    var title = manifest.title || (count === 0 ? "Empty drop" : plural(count, "file"));
    titleEl.textContent = title;
    document.title = title + " · " + document.title.split(" · ").slice(1).join(" · ");
    detailsEl.textContent = " · " + (count === 0 ? "No files" : plural(count, "file") + " · " + formatSize(total));
    listEl.textContent = "";
    manifest.files.forEach(function (file) {
      var item = element("li", "card");
      var row = element("div", "row");
      var icon = element("div", "icon k-" + kind(file.name));
      var glyph = document.getElementById("glyph-" + kind(file.name));
      if (glyph) icon.appendChild(glyph.content.cloneNode(true));
      var info = element("div", "info");
      var name = element("div", "name", file.name);
      name.title = file.name;
      var size = element("div", "size", formatSize(file.size));
      info.appendChild(name);
      info.appendChild(size);
      var button = element("button", "pill", "Download");
      button.type = "button";
      button.addEventListener("click", function () {
        download(file, key, button, size);
      });
      row.appendChild(icon);
      row.appendChild(info);
      row.appendChild(button);
      item.appendChild(row);
      listEl.appendChild(item);
    });
    listEl.hidden = false;
  }

  async function decryptTo(file, key, write, progress) {
    var response = await fetchObject("/" + dropId + "/" + file.id);
    var expected = XNE.ciphertextSize(file.size);
    var declared = response.headers.get("content-length");
    if (declared !== null && Number(declared) !== expected) throw fail("size");
    var reader = response.body.getReader();
    var received = 0;
    try {
      await XNE.decrypt(
        key,
        { kind: "file", dropId: dropId, objectId: file.id, size: file.size },
        async function () {
          var next = await reader.read();
          if (next.done) return null;
          received += next.value.length;
          if (received > expected) throw fail("trailing");
          return next.value;
        },
        async function (plaintext, index) {
          await write(plaintext);
          progress(Math.min(1, ((index + 1) * XNE.SEGMENT) / Math.max(1, file.size)));
        }
      );
    } finally {
      reader.cancel().catch(function () {});
    }
  }

  async function saveToDisk(file, key, progress) {
    // Must be the first await: the picker needs the click's user activation.
    var handle = await window.showSaveFilePicker({ suggestedName: file.name });
    var writable = await handle.createWritable();
    try {
      await decryptTo(file, key, function (plaintext) { return writable.write(plaintext); }, progress);
    } catch (e) {
      // Discards everything written so far; the chosen file is not replaced.
      await writable.abort().catch(function () {});
      throw e;
    }
    await writable.close();
  }

  async function saveFromMemory(file, key, progress) {
    var parts = [];
    await decryptTo(file, key, function (plaintext) { parts.push(new Blob([plaintext])); }, progress);
    // Authenticated: only now does the plaintext leave this page.
    var url = URL.createObjectURL(new Blob(parts, { type: "application/octet-stream" }));
    parts = null;
    var link = document.createElement("a");
    link.href = url;
    link.download = file.name;
    link.rel = "noopener";
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
  }

  async function download(file, key, button, sizeEl) {
    if (busy) return;
    var toDisk = file.size > MEMORY_LIMIT;
    if (toDisk && typeof window.showSaveFilePicker !== "function") {
      sizeEl.textContent = message(fail("too-large"));
      sizeEl.className = "size error-text";
      return;
    }
    busy = true;
    button.disabled = true;
    sizeEl.className = "size";
    var progress = function (fraction) {
      sizeEl.textContent = "Decrypting… " + Math.floor(fraction * 100) + "%";
    };
    progress(0);
    try {
      if (toDisk) await saveToDisk(file, key, progress);
      else await saveFromMemory(file, key, progress);
      sizeEl.textContent = formatSize(file.size) + " · Decrypted";
    } catch (e) {
      if (e && e.name === "AbortError" && !e.code) {
        sizeEl.textContent = formatSize(file.size);
      } else {
        sizeEl.textContent = message(e);
        sizeEl.className = "size error-text";
      }
    } finally {
      busy = false;
      button.disabled = false;
    }
  }

  async function start() {
    if (!window.isSecureContext || !window.crypto || !window.crypto.subtle) {
      show("This page can only decrypt files over HTTPS. Ask the sender for an https link.");
      return;
    }
    var key;
    try {
      key = XNE.parseKey(location.hash);
    } catch (e) {
      show(
        e.code === "missing-key"
          ? "This link is missing its key: the part after # was cut off. Ask the sender for the full link."
          : "This link's key is damaged. Copy the whole link again, including the part after #."
      );
      return;
    }
    try {
      render(await loadManifest(key), key);
    } catch (e) {
      switch (e.code) {
        case "pending":
          show("Files will appear here once they finish uploading.");
          break;
        case "auth":
          show("This key doesn't open these files. Check that you copied the whole link, including the part after #.");
          break;
        case "version":
        case "no-crypto":
          show(e.message);
          break;
        case "manifest":
        case "truncated":
        case "format":
          show("The list of files is damaged and can't be shown.");
          break;
        default:
          show("Couldn't load these files. Check your connection and reload.");
      }
    }
  }

  // A link pasted with a different key, or the key typed in later, should just work.
  window.addEventListener("hashchange", function () { location.reload(); });
  start();
})();
