<div align="center">

# XNotch

**There are a lot of good macOS Notch apps. But this one will be *yours*.**

[![Platform](https://img.shields.io/badge/platform-macOS-black?style=flat-square&logo=apple)](#)
[![Architecture](https://img.shields.io/badge/architecture-Modular-blue?style=flat-square)](#)
[![Vibe Coded](https://img.shields.io/badge/vibe_coded-100%25-purple?style=flat-square)](#)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](https://github.com/Lxvi101/XNotch/pulls)

</div>

---

## Chapter 1. Why another Notch App?

Look around and you'll find plenty of polished macOS notch apps. They look great in screenshots, pack in twenty different widgets, and try to turn the top of your screen into a mission control center.

So why build **XNotch**?

Because most notch apps try to be everything to everyone—and you end up paying for features you never touch, both in screen clutter and system resources. Other notch apps are *theirs*; you just rent space in how the developer thinks your Mac should work.

**XNotch is built to be *yours*.** 
It strips the concept down to a clean, fast core and treats every single feature as an optional module. Want media controls and a file shelf, but zero calendar or battery bloat? Done. Want a hyper-specific widget that only makes sense for your workflow? Drop it in as a module.

---

## Chapter 2. "Clearly this is some vibe-coded garbage"

Yes. It is heavily developed using AI. 

This is not my full-time job, and I don't have the free time to spend hundreds of hours hand-crafting boilerplate across the codebase. So yes, this project is **100% vibe-coded**.

**Then why choose this one?** 

Because I don't want a shitty, high-RAM app sitting in the background on my Mac—and I think neither do you. 

"Vibe-coded" doesn't mean unoptimized bloatware. Every design decision in XNotch is driven by one rule: **respect the machine**. 
- **Zero-Cost Disabled Modules:** Because XNotch is strictly modular, you only load what you actually use. If a module is turned off, it isn't sitting in memory polling system APIs in the background.
- **Lightweight Footprint:** No Electron wrappers, no hidden memory leaks, and no unnecessary background daemons eating up battery life just to render a black box at the top of your display.

---

## Chapter 3. Modular by Design

XNotch is split into two parts:
1. **The Core Engine:** Handles notch geometry, hover/click detection, smooth animations, and display switching with minimal overhead.
2. **The Modules:** Self-contained plugins that hook into the core.

### Current & Planned Modules
* **[Module 1 — e.g., Media HUD]:** Lightweight Now Playing controls and visualizer.
* **[Module 2 — e.g., Drop Shelf]:** Drag-and-drop temporary file holding right in the notch.
* **[Module 3 — e.g., System Glance]:** Quick, event-driven HUD replacements.
* *(Swap these placeholders out with your currently active modules!)*

---

## Chapter 4. Installation

### Option 1: Download Release
1. Grab the latest `.dmg` or `.zip` from the [Releases](https://github.com/Lxvi101/XNotch/releases) page.
2. Drag **XNotch.app** into your `/Applications` folder.
3. Launch XNotch and grant the required permissions (Accessibility / Screen Recording if required by your active modules).

> **Note:** If macOS Gatekeeper complains that the app is from an unidentified developer, run:
> ```bash
> xattr -cr /Applications/XNotch.app
> ```

### Option 2: Build from Source
1. Clone the repository:
   ```bash
   git clone [https://github.com/Lxvi101/XNotch.git](https://github.com/Lxvi101/XNotch.git)
   cd XNotch
