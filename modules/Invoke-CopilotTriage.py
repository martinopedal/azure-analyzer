#!/usr/bin/env python3
"""
Invoke-CopilotTriage.py — AI triage enrichment for azure-analyzer findings.

Uses the GitHub Copilot SDK (github-copilot-sdk, preview 0.1.x) to enrich
non-compliant assessment findings with priority ranking, risk context,
remediation guidance, and root-cause grouping.

Requires: pip install github-copilot-sdk
Auth:     COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN env var, or gh auth login
"""

import argparse
import asyncio
import json
import os
import sys

try:
    from copilot import CopilotClient
except ImportError:
    print(
        "ERROR: github-copilot-sdk is not installed.\n"
        "Install with: pip install github-copilot-sdk",
        file=sys.stderr,
    )
    sys.exit(1)

SYSTEM_PROMPT = """\
You are an Azure security and compliance expert.
You are triaging assessment findings from multiple tools \
(azqr, PSRule, AzGovViz, ALZ queries, WARA, Maester, Scorecard).
For each batch of findings, provide:
1. Priority ranking (1 = fix first) based on blast radius and exploitability
2. Risk context: what happens if this isn't fixed
3. Specific remediation steps (not just "see docs")
4. Group related findings that share a root cause

Respond ONLY with a JSON array. Each element must have exactly these fields:
{"Id":"<id>","AiPriority":<int 1-N>,"AiRiskContext":"<text>",\
"AiRemediation":"<text>","AiRelatedFindings":["<id>",...]}

Rules:
- One element per finding in the batch.
- AiPriority must be unique within the batch (no ties).
- AiRelatedFindings lists Ids of OTHER findings sharing a root cause (empty if none).
- Do NOT wrap in markdown code fences. No text outside the JSON array."""

# Preferred models, tried in order. Actual availability checked via list_models().
PREFERRED_MODELS = ["gpt-4.1", "claude-sonnet-4", "gpt-5-mini"]
BATCH_SIZE = 12
MAX_RETRIES = 3
BASE_DELAY = 2.0


def load_findings(path: str) -> list[dict]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict) and "Findings" in data:
        return data["Findings"]
    if isinstance(data, list):
        return data
    raise ValueError(f"Unexpected JSON structure in {path}")


def batch_findings(findings: list[dict]) -> list[list[dict]]:
    severity_order = {"High": 0, "Medium": 1, "Low": 2, "Info": 3}
    ordered = sorted(
        findings,
        key=lambda f: severity_order.get(f.get("Severity", "Info"), 3),
    )
    return [ordered[i : i + BATCH_SIZE] for i in range(0, len(ordered), BATCH_SIZE)]


def build_prompt(batch: list[dict]) -> str:
    fields = ("Id", "Source", "Category", "Title", "Severity",
              "Detail", "Remediation", "ResourceId")
    simplified = [{k: f.get(k, "") for k in fields} for f in batch]
    return (
        f"Triage these {len(batch)} non-compliant Azure assessment findings. "
        f"Prioritise by blast radius and exploitability.\n\n"
        f"{json.dumps(simplified, indent=2)}"
    )


def parse_response(text: str) -> list[dict]:
    text = text.strip()
    # Strip markdown code fences if the model wrapped its response
    if text.startswith("```"):
        lines = [l for l in text.split("\n") if not l.strip().startswith("```")]
        text = "\n".join(lines).strip()
    return json.loads(text)


async def resolve_models(client: CopilotClient) -> list[str]:
    """Pick models from PREFERRED_MODELS that are actually available."""
    try:
        available = {m.id for m in await client.list_models()}
        models = [m for m in PREFERRED_MODELS if m in available]
        if models:
            return models
        # None of our preferred models matched — use whatever is available
        print(
            f"  Preferred models not found. Available: {sorted(available)}",
            file=sys.stderr,
        )
        return sorted(available)[:3] if available else PREFERRED_MODELS
    except Exception as exc:
        print(f"  Could not list models ({exc}), using defaults.", file=sys.stderr)
        return PREFERRED_MODELS


async def triage_batch(
    client: CopilotClient,
    models: list[str],
    batch: list[dict],
    batch_index: int,
    total_batches: int,
) -> dict[str, dict]:
    prompt = build_prompt(batch)
    batch_ids = {f.get("Id") for f in batch}

    for model in models:
        for attempt in range(MAX_RETRIES):
            try:
                print(
                    f"  Batch {batch_index + 1}/{total_batches}: "
                    f"model={model}, attempt={attempt + 1}/{MAX_RETRIES}",
                    file=sys.stderr,
                )
                async with await client.create_session(
                    model=model, system_message=SYSTEM_PROMPT
                ) as session:
                    response = await session.send(prompt)

                enrichments = parse_response(response)
                if not isinstance(enrichments, list):
                    raise ValueError("AI response is not a JSON array")
                return {e["Id"]: e for e in enrichments if e.get("Id") in batch_ids}

            except json.JSONDecodeError as exc:
                print(f"    JSON parse error: {exc}", file=sys.stderr)
            except Exception as exc:
                print(f"    Error: {exc}", file=sys.stderr)

            await asyncio.sleep(BASE_DELAY * (2 ** attempt))

        print(f"    Model {model} exhausted retries, trying next.", file=sys.stderr)

    print(
        f"  WARNING: Batch {batch_index + 1} failed on all models.",
        file=sys.stderr,
    )
    return {}


async def run_triage(input_path: str, output_path: str, token: str) -> None:
    all_findings = load_findings(input_path)
    non_compliant = [f for f in all_findings if not f.get("Compliant", True)]

    if not non_compliant:
        print("No non-compliant findings to triage.", file=sys.stderr)
        write_output(all_findings, {}, output_path)
        return

    print(f"Triaging {len(non_compliant)} non-compliant findings...", file=sys.stderr)

    # Privacy notice (mandatory)
    print(
        "NOTE: Non-compliant finding data (titles, details, resource IDs) "
        "will be sent to GitHub Copilot services for analysis.",
        file=sys.stderr,
    )

    batches = batch_findings(non_compliant)
    print(f"Split into {len(batches)} batch(es) of up to {BATCH_SIZE}.", file=sys.stderr)

    # Pass token explicitly; SDK also checks GITHUB_TOKEN env and gh auth login
    async with CopilotClient(github_token=token) as client:
        models = await resolve_models(client)
        print(f"Using models: {', '.join(models)}", file=sys.stderr)

        all_enrichments: dict[str, dict] = {}
        for i, batch in enumerate(batches):
            result = await triage_batch(client, models, batch, i, len(batches))
            all_enrichments.update(result)

    write_output(all_findings, all_enrichments, output_path)
    print(
        f"Triage complete. {len(all_enrichments)}/{len(non_compliant)} "
        f"findings enriched.",
        file=sys.stderr,
    )


def write_output(
    all_findings: list[dict],
    enrichments: dict[str, dict],
    output_path: str,
) -> None:
    output = []
    for f in all_findings:
        entry = dict(f)
        fid = f.get("Id", "")
        if fid in enrichments:
            ai = enrichments[fid]
            entry.update(
                AiPriority=ai.get("AiPriority"),
                AiRiskContext=ai.get("AiRiskContext", ""),
                AiRemediation=ai.get("AiRemediation", ""),
                AiRelatedFindings=ai.get("AiRelatedFindings", []),
            )
        else:
            entry.update(
                AiPriority=None, AiRiskContext="",
                AiRemediation="", AiRelatedFindings=[],
            )
        output.append(entry)

    output.sort(key=lambda x: (x["AiPriority"] is None, x["AiPriority"] or 9999))
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"Wrote triage output to {output_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="AI triage enrichment for azure-analyzer findings"
    )
    parser.add_argument("--input", default=os.path.join("output", "results.json"))
    parser.add_argument("--output", default=os.path.join("output", "triage.json"))
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    # Resolve token: COPILOT_GITHUB_TOKEN > GH_TOKEN > GITHUB_TOKEN
    # The SDK constructor also accepts github_token= or falls back to GITHUB_TOKEN / gh auth login
    token = (
        os.environ.get("COPILOT_GITHUB_TOKEN")
        or os.environ.get("GH_TOKEN")
        or os.environ.get("GITHUB_TOKEN")
    )
    if not token:
        print(
            "ERROR: No Copilot token found. Set COPILOT_GITHUB_TOKEN, "
            "GH_TOKEN, or GITHUB_TOKEN with a PAT that has the 'copilot' scope.",
            file=sys.stderr,
        )
        sys.exit(1)

    if token.startswith("ghs_"):
        print(
            "ERROR: GitHub Actions tokens (ghs_) do not have Copilot API access. "
            "Use a PAT (github_pat_), OAuth (gho_), or user (ghu_) token.",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        asyncio.run(run_triage(args.input, args.output, token))
    except Exception as exc:
        print(f"ERROR: Triage failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
