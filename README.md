# MacDown, modernized

This is a modernized version of [MacDown](https://github.com/MacDownApp/macdown),
the open source Markdown editor for macOS. It targets macOS 13 or later and
builds for Apple Silicon and Intel.

The changes were made through repeated rounds of optimization and testing:
measure rendering speed and memory use, change the code, run checks, and compare
again. The work keeps MacDown's editor, preferences, and document features while
updating the app for current macOS.

## Changes in this version

- The preview uses WKWebView. Ordinary edits update the existing page and keep
  unchanged images and code blocks in place.
- Markdown parsing and syntax highlighting run off the main thread. Rapid edits
  cancel older work instead of building up a queue.
- You can edit rendered text in the preview. Selecting preview text also selects
  its Markdown in the source pane.
- The build pins its dependencies, shares version numbers, and has an optional
  GitHub macOS job. Pushes do not start a macOS build.

## Get the app

Download the app from this fork's
[GitHub releases](https://github.com/juliendorra/macdown/releases).
Unzip `MacDown-0.8.1-macOS.zip` and move `MacDown.app` to Applications.
The download runs on Apple Silicon and Intel Macs with macOS 13 or later.

You can also build it locally using the instructions below, or run the optional Mac build in
[GitHub Actions](https://github.com/juliendorra/macdown/actions/workflows/ci.yml).
Select the branch you want to build and enable **Build and test the universal
Mac app**. Download the resulting `MacDown-macOS-*` artifact, unzip the app, and
move it to Applications.

The app is signed locally without an Apple developer certificate and is not
notarized. The original project's releases and Homebrew package do not contain
this fork's changes.

## Editing in the preview

Click rendered text and type. Edits preserve the surrounding Markdown formatting
and use the document's normal undo, save, and autosave behavior. Preview
selections highlight the matching source without moving keyboard focus.

Pasted text stays plain text. Command-Z undoes edits; Shift-Command-Z redoes them.
Return starts a paragraph or continues a list. Shift-Return inserts a Markdown
line break. Command-click opens a link; an ordinary click edits its label.

Some generated content, raw HTML, and selections across formatting boundaries
cannot be mapped safely to Markdown. The preview asks you to edit those in the
source pane. An outdated preview cannot overwrite newer source text.

## Build locally

Install full Xcode, Ruby 3.3 or later, and Bundler 2.4.22. Command Line Tools alone
cannot compile the app's Interface Builder documents.

```sh
gem install bundler -v 2.4.22
Scripts/check.sh
Scripts/check-macos-local.sh
Scripts/build-macos.sh
open Artifacts/MacDown.app
```

The build installs the locked dependencies, runs the native tests, and produces
a universal app in one Xcode invocation. Outputs are `Artifacts/MacDown.app`,
`Artifacts/MacDown-macOS.zip`, and the XCTest result bundle. Set
`CODESIGN_IDENTITY` to use an existing signing identity.

For development, run `Scripts/setup.sh` and open `MacDown.xcworkspace`. The
checked-in GitHub stylesheet needs no npm step during an app build.

Version and build number are stored in `Tools/version.txt` and
`Tools/build-number.txt`. The app and command-line tool use the same values.

## Tests and performance

`Scripts/check.sh` runs the portable parser, source-selection, and project
checks. `Scripts/check-macos-local.sh` checks the AppKit toolbar with Command
Line Tools. `Scripts/build-macos.sh` runs the full XCTest suite with Xcode.

The local preview checks run against an already built development app:

```sh
python3 Scripts/check-preview-editing.py Artifacts/MacDown.app
```

They use temporary documents and isolated preferences. They cover native
keyboard input, Japanese text composition, undo, saving, Unicode, formatting,
code indentation, tables, empty documents, and typing during preview refreshes.
GUI checks need an awake, unlocked macOS desktop session. The launcher stops
before opening an app if it detects a restricted sandbox, a sleeping display,
or a locked session.

For manual checks, try a large document, fast typing, scrolling, links, themes,
zoom, HTML/PDF export, and closing a document while it renders. MathJax uses its
configured CDN connection.

### Compare changes without a cloud build

`Scripts/rebuild-macos-local.py` compiles the app and installed source
dependencies with Command Line Tools. It reuses compiled nibs and assets from
an existing app after checking that their source files, project settings,
dependency locks, and versions match. Interface changes need full Xcode.
This local rebuild does not run XCTest.

Build both revisions with the same compiler and dependencies. Supply the app
and source revision that produced the compiled resources:

```sh
python3 Scripts/rebuild-macos-local.py \
  --resources-app /path/to/existing/MacDown.app --resources-ref RESOURCE_COMMIT \
  --source-ref BEFORE_COMMIT --output .build/compare/before/MacDown.app
python3 Scripts/rebuild-macos-local.py \
  --resources-app /path/to/existing/MacDown.app --resources-ref RESOURCE_COMMIT \
  --output .build/compare/after/MacDown.app
python3 Scripts/benchmark-preview.py \
  .build/compare/before/MacDown.app .build/compare/after/MacDown.app
```

Local rebuilds use the host architecture unless you add `--universal`.
The benchmark reverses app order between runs, records edit latency after
warmup, and measures the app plus its new WebKit helper processes. It also
checks images, highlighting, script behavior, scrolling, printing, and closing.
Run it on a quiet machine; shared memory and other processes affect readings.

In comparisons of earlier and later revisions of this fork, a roughly
7,000-line document went from 268 ms to 200 ms median edit-to-preview latency.
Measured memory after edits went from 214 MiB to 141 MiB. With preview editing
added, a later single run measured 199 ms and 155 MiB. The tests used Apple
Silicon, macOS 27, clang 15, and SDK 14.4.

These figures include the 120 ms typing delay and end at DOM readiness, not
screen paint. Memory varies by document and stage of use. The original
Intel-only MacDown could not run on the test machine, so these numbers do not
establish a reduction against that release.

Selection maps are built when the preview is used. After an edit, the app first
maps the changed block and reuses the known caret while typing. Ordinary source
edits avoid rebuilding a document-wide selection map. The editing bridge runs
in an isolated WebKit content world, separate from scripts in Markdown.

## GitHub builds

Pushes and pull requests run Linux checks. The macOS job runs only when the
workflow is started manually with the Mac build option enabled. It waits for
the portable checks, caches dependencies, and tests and builds the universal
app once. The job has a 20-minute timeout. Build artifacts are kept for three
days.

Batch fixes and run the cheaper checks first. Check the results for the exact
commit before starting another Mac build.

## Updates

Sparkle 2 is included. Automatic updates stay disabled until a distributor
supplies its own `SUFeedURL` and `SUPublicEDKey` in the app's Info.plist. Do not
use the original project's update feed or signing key for this fork.

## License and credits

MacDown is released under the MIT License. This fork builds on the original
[MacDown project](https://github.com/MacDownApp/macdown), inspired by
[Mou](http://mouapp.com). Some bundled themes and styles also come from Mou.
Copyright notices and third-party licenses are in [LICENSE](LICENSE).

Translations are maintained through the original project's
[Transifex page](https://www.transifex.com/macdown/macdown/). Report issues with
this version in [this fork](https://github.com/juliendorra/macdown/issues).
