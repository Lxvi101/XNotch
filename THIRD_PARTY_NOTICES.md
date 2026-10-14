# Third-party notices

XNotch is distributed under GPL-3.0-or-later. See LICENSE. Individual files retain their attribution notices.

- **Atoll / boring.notch**: portions of Now Playing handling, shelf interactions, thumbnails, drag detection and headphone detection adapted under GPL-3.0-or-later. The headphone animations in ThirdParty/Atoll/Headphones come from Atoll. Copyright 2024–2026 their contributors. Sources: https://github.com/Ebullioscopic/Atoll and https://github.com/TheBoredTeam/boring.notch.
- **mediaremote-adapter**: Copyright 2025 Jonas van den Berg. BSD 3-Clause; the full license is in ThirdParty/mediaremote-adapter/LICENSE. Source: https://github.com/ungive/mediaremote-adapter. The included framework and Perl adapter enable Now Playing on recent macOS versions.
- **SkyLightWindow**: Copyright 2025 Lakr Aream. The SkyLight space integration is adapted under MIT; its permission notice is retained in XNotch/App/LockScreen/SkyLightSpace.swift.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

- **PermissionFlow** (Copyright 2026 小弟调调, https://github.com/jaywcjlove/PermissionFlow) and **AskForPermission** (Copyright 2026 Riko, https://github.com/riko2chen/AskForPermission), both MIT: the permission guide in XNotch/App/Permissions reimplements their approach (a guide docked under System Settings, a draggable app bundle, polling for the grant).
- **bloub** (Copyright 2026 Jérémy Perret, https://github.com/jeremy-prt/bloub), MIT: the notch eyes in XNotch/App/Notch/NotchEyes.swift use its measured eye proportions, expressions and blink timing.
- **Sparkle 2.10.0**: Copyright Sparkle Project contributors. Its full license, including incorporated components, is in ThirdParty/Sparkle/LICENSE. Source: https://github.com/sparkle-project/Sparkle. Distributed through Swift Package Manager.
- **CodexBar** (Copyright 2026 Peter Steinberger, https://github.com/steipete/CodexBar, commit 5fdb2c79), MIT: the AI Usage extension in Extensions/AIUsage adapts its Claude, Cursor and Codex usage requests, response decoding and unit rules (the Claude and Codex usage fetchers, the Cursor app session reader and usage summary, the saved-reset inventories, and the scoped and additional rate-limit mappers). The adapted files say so at the top. The full license is in ThirdParty/CodexBar/LICENSE and in the extension bundle.

Release app bundles include this notice, the GPL, and the mediaremote-adapter, Sparkle and CodexBar licenses in Contents/Resources.
