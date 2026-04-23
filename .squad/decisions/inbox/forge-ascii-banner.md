# Decision: ASCII Banner Redesign (#964)

**Author:** Forge
**Date:** 2026-04-25
**PR:** #975
**Closes:** #964

## Context

The original console banner used a single merged figlet rendering where "Azure" and "analyzer" were combined into one art block, making both words hard to read. Issue #964 requested a redesign with clear word separation and multi-color support.

## Decision

Replaced the merged banner with a two-block Standard figlet layout:
- **AZURE** (5 lines) rendered in **Cyan**
- **ANALYZER** (5 lines) rendered in **Yellow**
- Version line in **DarkGray**

Standard figlet font chosen for maximum terminal compatibility (7-bit ASCII only). Max width: 50 chars (ANALYZER block), well under the 80-char constraint.

## Rationale

- Two-block layout makes both words immediately readable
- Multi-color leverages Write-Host -ForegroundColor (no ANSI escape codes), compatible with all PowerShell hosts
- DarkGray version line creates visual hierarchy without competing with the brand colors
- NO_COLOR env var support maintained per no-color.org spec
- Writer path (for testing) outputs all blocks sequentially without color

## Impact

- **Console only** — banner does not appear in HTML/MD reports
- **SampleDrift: unaffected** — verified by running SampleDrift.Tests.ps1
- **Banner.Tests.ps1** — all 9 tests pass; added Yellow color assertion
- **Function signature unchanged** — Show-Banner / Write-AzureAnalyzerBanner API is backward-compatible

## Status

**Proposed** — awaiting PR merge.
