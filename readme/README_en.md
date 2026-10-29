<h4 align="right">
  <a href="../README.md">简体中文</a> | <strong>English</strong> | <a href="README_ru.md">Русский</a> | <a href="README_fa.md">فارسی</a> | <a href="README_ja.md">日本語</a> | <a href="README_ko.md">한국어</a>
</h4>

<h1 align="center">⚡ Angela Mihomo</h1>
<p align="center">
  <strong>A Mihomo client with enhanced chained-proxy support</strong>
</p>

## About this project

**Angela Mihomo** is a cross-platform proxy client built on the [Mihomo](https://github.com/MetaCubeX/mihomo) core, focused on chained proxying, system-level leak protection and an out-of-the-box experience. It is developed and released independently under the GPL-3.0 license.

Release announcements: https://t.me/AngelaNexus

Highlights:

* **Chained-proxy enhancements**: both the entry and the exit hop may be a proxy group; the exit may be selected from another profile; an empty entry group is automatically hardened to reject direct fallback so a broken chain cannot silently bypass.
* **System-explicit leak protection**: WebRTC blocking, China public-DNS direct routing, ad blocking and related explicit rules, unified with the chain policy and effective out of the box.
* **Independent package identity**: the Android application id is `app.angelabettbox`, so it can be installed alongside other clients; the id stays stable so existing installs upgrade in place.
* **Core and data alignment**: the bundled Mihomo core tracks official Mihomo releases (currently v1.19.33), and built-in rule data comes from the official MetaCubeX/meta-rules-dat source.

## Downloads

Get packages for your platform from this repository's **[Releases](https://github.com/dukangalex/AngelaMihomo/releases)** page (Windows, Linux, macOS, Android, Android TV).

**Migrating from another build (Android)**: since v1.19.7-chain.1 this app uses its own package name and installs alongside other builds; export a backup in the other app first, then import it here.

## Acknowledgements

* **[Bettbox](https://github.com/appshubcc/Bettbox)** — the original project this codebase descends from; thanks to appshubcc and all contributors.
* **[FlClash](https://github.com/chen08209/FlClash)** — the lineage origin.
* **[Mihomo](https://github.com/MetaCubeX/mihomo)** — the core engine.

## License

GPL-3.0 — see [LICENSE](../LICENSE). Full source lives in this repository.
