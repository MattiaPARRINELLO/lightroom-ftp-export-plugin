# Lightroom to FTP Export Plugin

A free, lightweight Lightroom Classic plugin that lets you export photos directly to an FTP server — no manual export-then-upload step, no other third-party plugin required.

Built and maintained by [Pixilive](https://about.pixi.live), a real-time photo management platform for professional events.

## Why this plugin

Lightroom Classic doesn't include FTP export out of the box. Most existing FTP export plugins are either outdated, paid, or both. This one is free, actively maintained, and works with **any** FTP server — not just Pixilive's.

## Features

- Direct FTP export from Lightroom Classic (server, username, password, port, active/passive mode)
- Password stored securely in your system's keychain — never written to disk in plain text
- Works with any FTP server, not just Pixilive
- Recommended export settings (JPEG, 2048px long edge, 72 dpi, full metadata) applied automatically when exporting to the Pixilive server
- Behaves like any standard Lightroom export preset

## Installation

1. Download the latest `.zip` from the [Releases](../../releases) page.
2. Unzip it. You should get a folder named `Pixilive-FTP-Uploader.lrplugin`.
3. Move that folder somewhere permanent on your disk (Lightroom reads it in place, it doesn't copy it).
4. In Lightroom Classic: **File → Plug-in Manager...**
5. Click **Add**, then select the `Pixilive-FTP-Uploader.lrplugin` folder.
6. Confirm the status shows **"Installed and running"**.

## Usage

1. Select your photos, then **File → Export...**
2. Under **"Export To:"**, choose **"Pixilive FTP Uploader"**.
3. Enter your FTP server, username, and password.
4. Click **Export**.

Tip: once configured, save these settings as a Lightroom **Export Preset** (the "Add" button at the bottom-left of the export dialog) so you don't have to re-enter them next time.

To export to a different FTP server, just replace the "Server" field — the plugin works generically with any FTP host.

## Compatibility

Lightroom Classic, macOS and Windows. Requires a valid FTP account.

## About Pixilive

[Pixilive](https://about.pixi.live) is a real-time photo distribution platform for professional events (conferences, trade shows, seminars). Organizers get instant, no-app-required photo delivery to attendees, speakers, and partners — with measurable engagement stats.

## Support

Questions or issues? Contact contact@pixi.live or visit [about.pixi.live](https://about.pixi.live).
