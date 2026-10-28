<h4 align="right">
  <a href="../README.md">简体中文</a> | <strong>English</strong> | <a href="README_ru.md">Русский</a> | <a href="README_fa.md">فارسی</a> | <a href="README_ja.md">日本語</a> | <a href="README_ko.md">한국어</a>
</h4>

<h1 align="center">⚡ Angela Mihomo</h1>
<p align="center">
  <strong>A Mihomo client with enhanced chained-proxy support</strong>
</p>

## About this project

**Angela Mihomo is an independently maintained fork of [Bettbox](https://github.com/appshubcc/Bettbox)** (formerly published as AngelaBettbox; renamed on 2026-10-28). The original project is developed by appshubcc (descended from [FlClash](https://github.com/chen08209/FlClash)), is built on the [Mihomo](https://github.com/MetaCubeX/mihomo) core, and is licensed under GPL-3.0. This fork enhances chained-proxy support and is released independently; **it is not affiliated with the original project**. The original project's communities, sponsorship and service recommendations belong to the original project and are not carried over here.

Release announcements: https://t.me/AngelaNexus

Differences from upstream:

* **Chained-proxy enhancements**: both the entry and the exit hop may be a proxy group; the exit may be selected from another profile; an empty entry group is automatically hardened to reject direct fallback so a broken chain cannot silently bypass.
* **Independent package identity**: the Android application id is `app.angelabettbox`, so it can be installed alongside the upstream app; the id is kept unchanged across the rename so existing installs upgrade in place.
* **Version and core alignment**: version numbers track upstream Bettbox releases, and the bundled Mihomo core baseline matches the one shipped by upstream (currently Mihomo v1.19.33).
* All other features and the UI remain aligned with upstream; fork-specific changes are listed in each release's notes.

## Downloads

Get packages for your platform from this repository's **[Releases](https://github.com/dukangalex/AngelaMihomo/releases)** page (Windows, Linux, macOS, Android, Android TV).

**Migrating from upstream (Android)**: since v1.19.7-chain.1 this fork uses its own package name and installs alongside the original app; export a backup in the original app first, then import it here.

## Acknowledgements

* **[Bettbox](https://github.com/appshubcc/Bettbox)** — the original project this fork is based on; thanks to appshubcc and all upstream contributors.
* **[FlClash](https://github.com/chen08209/FlClash)** — the lineage origin.
* **[Mihomo](https://github.com/MetaCubeX/mihomo)** — the core engine.

## License

GPL-3.0 — see [LICENSE](../LICENSE). All modifications in this fork are published under GPL-3.0 as well, with full source in this repository.
