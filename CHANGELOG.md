# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows semantic-style release notes where practical.

## [Unreleased]

### Added
- Added `LICENCE` with GNU General Public License v3.0 text.
- Added `CHANGELOG.md` to track project changes.

## [2026-10-27]

### Changed
- README refocused to TIB-first DevOps deployment workflow.
- Added TIB infrastructure ASCII schematic at the top of README.
- Main workflow emphasized as DEV -> TEST -> PROD.
- IMPORT documented as a disconnected clean sandbox for import tests.
- Added local experimental loop documentation (CLEAN -> EXPERIMENTAL -> approve/rollback).

### Infrastructure
- Primary git remote switched to TIB GitLab deployment repository.
- GitHub remote retained as backup mirror.
