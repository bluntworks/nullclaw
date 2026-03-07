# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [CalVer](https://calver.org/) versioning (YYYY.M.D).

## [Unreleased]

## [2026.3.7]

### Security

- Docker mount path validation: reject traversal sequences, system directories, and colons
- Constant-time pairing code comparison to prevent timing attacks

### Added

- `yolo` autonomy level for unrestricted mode

### Changed

- `/think on` as alias for medium autonomy (#330)

### Fixed

- Slack markdown-to-mrkdwn conversion (#325)
- Telegram empty draft rejection (#329)
- Reasoning parameter hardening (#318)
