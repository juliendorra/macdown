# MacDown

[![](https://img.shields.io/github/release/MacDownApp/macdown.svg)](http://macdown.uranusjr.com/download/latest/)
![Total downloads](https://img.shields.io/github/downloads/MacDownApp/macdown/latest/total.svg)


MacDown is an open source Markdown editor for macOS, released under the MIT License. The author stole the idea from [Chen Luo](https://twitter.com/chenluois)’s [Mou](http://mouapp.com) so that people can make crappy clones.

Visit the [project site](http://macdown.uranusjr.com/) for more information, or download [MacDown.app.zip](http://macdown.uranusjr.com/download/latest/) directly from the [latest releases](https://github.com/MacDownApp/macdown/releases/latest) page.

## Install

[Download](http://macdown.uranusjr.com/download/latest/), unzip, and drag the app to Applications folder. MacDown is also available through [Homebrew Cask](https://caskroom.github.io/):

    brew install --cask macdown

## Screenshot

![screenshot](assets/screenshot.png)

## License

MacDown is released under the terms of MIT License. You may find the content of the license [here](http://opensource.org/licenses/MIT), or inside the `LICENSE` directory.

You may find full text of licenses about third-party components in the `LICENSE` directory, or the **About MacDown** panel in the application.

The following editor themes and CSS files are extracted from [Mou](http://mouapp.com), courtesy of Chen Luo:

* Mou Fresh Air
* Mou Fresh Air+
* Mou Night
* Mou Night+
* Mou Paper
* Mou Paper+
* Tomorrow
* Tomorrow Blue
* Tomorrow+
* Writer
* Writer+
* Clearness
* Clearness Dark
* GitHub
* GitHub2

## Development

### Requirements and local builds

This modernization targets macOS 13 or later on Apple Silicon and Intel,
including current macOS. It preserves the AppKit editor and document features
and uses WKWebView for previews, scrolling, printing, and HTML text counting.

Install full Xcode (Command Line Tools alone cannot compile this app's Interface
Builder documents), Ruby 3.3+, and Bundler 2.4.22:

```sh
gem install bundler -v 2.4.22
Scripts/check.sh         # portable parser and project checks, no Apple CI
Scripts/check-macos-local.sh # AppKit toolbar checks with CLT and bounds sanitizers
Scripts/build-macos.sh   # dependencies, native tests, universal app, signature
open Artifacts/MacDown.app
```

The build produces `Artifacts/MacDown.app`, `Artifacts/MacDown-macOS.zip`, and an
XCTest result bundle. The default signature is ad hoc for local use; it is not
notarized. `CODESIGN_IDENTITY` can select an existing local identity. This flow
uses the same local packaging and explicit Apple-build pattern as Mavica Copy,
Padipop, and Ripmix. It does not publish an App Store release.

For development, run `Scripts/setup.sh` and open `MacDown.xcworkspace`. The
checked-in GitHub stylesheet needs no npm step during app builds.

### CI and macOS minutes

Pushes to the default branch and pull requests run inexpensive Linux checks.
The **Check MacDown and optional Mac app** workflow runs a macOS job only when
manually dispatched with `apple_build=true`. The default is portable checks only.
The Mac job waits for those checks, caches dependencies, tests and builds the
universal app in one Xcode invocation, and uploads the app and test results for
three days. Superseded validation cancels, and a 20-minute timeout bounds the
single macOS job. There are no automatic macOS push/PR builds or build matrix.

Batch changes, inspect runs for the exact commit, and dispatch the Apple job once
when needed. Do not rerun an already successful revision merely to package it.

Version and build number live in `Tools/version.txt` and `Tools/build-number.txt`.
The app and CLI use the same values in local and CI builds. For a new requested
TestFlight/App Store release, increment both values before CI and verify the
archived pair before uploading.

### Updating

Sparkle 2 replaces the Intel-only legacy updater. Local builds leave update
checking disabled until a distributor supplies its own `SUFeedURL` and
`SUPublicEDKey` in the app's Info.plist. Do not reuse the old upstream DSA key or
feed for a fork. A beta feed can optionally be configured with `SUBetaFeedURL`.

### Performance and regression checks

Markdown parsing and syntax highlighting debounce edits, cancel queued work,
and discard stale results. Parser state stays off the main thread; AppKit state
is read on the main thread. Preview loads retain only the newest pending HTML,
scroll messages coalesce, and document close invalidates pending callbacks.

Native tests cover rapid edits, cancellation, relative preview images, and
printing alongside the existing test suite. For manual review, open a large
Markdown document, type quickly, scroll both panes, test anchor/external links,
copy HTML, export HTML/PDF, change themes/zoom, and close while rendering.
MathJax still requires its configured CDN connection.

Local physical-memory measurements of the delivered Xcode build on Apple
Silicon/macOS 27 were approximately 112 MiB with a small document and 164 MiB
with a 7,000-line (109 KiB) document,
including the editor and its newly created WebKit content, GPU, and networking
processes. Both previews rendered successfully. Closing the document released
about 24–37 MiB from the editor after settling. These are single-run observations,
not a memory limit or a leak test. The installed Intel-only legacy app could not
run on this host, so a reduction versus legacy MacDown has not been established.
Large documents, scripts, images, and multiple windows can use more memory.

### Translation

Please help translation on [Transifex](https://www.transifex.com/macdown/macdown/).

![Transifex translation percentage](https://www.transifex.com/projects/p/macdown/resource/macdownxliff/chart/image_png/)

## Discussion

[![Gitter](https://badges.gitter.im/Join%20Chat.svg)](https://gitter.im/MacDownApp/macdown)

Join our [Gitter channel](https://gitter.im/MacDownApp/macdown) if you have any problems with MacDown. Any suggestions are welcomed, too!

You can also [file an issue directly](https://github.com/MacDownApp/macdown/issues/new) on GitHub if you prefer so. But please, **search first to make sure no-one has reported the same issue already** before opening one yourself. MacDown does not update in your computer immediately when we make changes, so something you experienced might be known, or even fixed in the development version.

MacDown depends a lot on other open source projects, such as [Hoedown](https://github.com/hoedown/hoedown) for Markdown-to-HTML rendering, [Prism](http://prismjs.com) for syntax highlighting (in code blocks), and [PEG Markdown Highlight](https://github.com/ali-rantakari/peg-markdown-highlight) for editor highlighting. If you find problems when using those particular features, you can also consider reporting them directly to upstream projects as well as to MacDown’s issue tracker. I will do what I can if you report it here, but sometimes it can be more beneficial to interact with them directly.

## Tipping

If you find MacDown suitable for your needs, please consider [giving me a tip through PayPal](http://macdown.uranusjr.com/faq/#donation). Or, if you prefer to buy me a drink *personally* instead, just [send me a tweet](https://twitter.com/uranusjr) when you visit [Taipei, Taiwan](http://en.wikipedia.org/wiki/Taipei), where I live. I look forward to meeting you!
