#!/usr/bin/env python3
"""
Automated self-evolving loop for planning prompts.

Loop:
1) Run eval suite (live_llm)
2) If below target avg_final_score, gather failed cases
3) Ask an optimizer model for an improved single-call system prompt
4) Re-run with the improved prompt via --custom-system-prompt-file
"""

from __future__ import annotations

import argparse
import configparser
import datetime as dt
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any

VERSION_REGISTRY_REL = pathlib.Path("tools/evals/self_evolve/prompt_versions.json")
VERSION_ARTIFACTS_REL = pathlib.Path("tools/evals/self_evolve/prompt_versions")


def _utc_stamp() -> str:
    return dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def _load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2), encoding="utf-8")


def _write_text(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _godot_userdata_root() -> pathlib.Path:
    home = pathlib.Path.home()
    sys_name = platform.system().lower()
    if "darwin" in sys_name:
        return home / "Library" / "Application Support" / "Godot" / "app_userdata"
    if "windows" in sys_name:
        appdata = os.environ.get("APPDATA", "").strip()
        if appdata:
            return pathlib.Path(appdata) / "Godot" / "app_userdata"
        return home / "AppData" / "Roaming" / "Godot" / "app_userdata"
    return home / ".local" / "share" / "godot" / "app_userdata"


def _project_display_name(project_root: pathlib.Path) -> str:
    project_file = project_root / "project.godot"
    if not project_file.exists():
        return ""
    text = project_file.read_text(encoding="utf-8", errors="ignore")
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line.startswith("config/name="):
            continue
        rhs = line.split("=", 1)[1].strip()
        if rhs.startswith('"') and rhs.endswith('"') and len(rhs) >= 2:
            return rhs[1:-1]
        return rhs
    return ""


def _read_api_key_from_llm_settings(project_root: pathlib.Path) -> str:
    app_name = _project_display_name(project_root)
    if not app_name:
        return ""
    cfg_path = _godot_userdata_root() / app_name / "llm_ai_settings.cfg"
    if not cfg_path.exists():
        return ""
    parser = configparser.ConfigParser()
    try:
        parser.read(cfg_path, encoding="utf-8")
    except Exception:
        return ""
    if not parser.has_section("llm_ai"):
        return ""
    raw = parser.get("llm_ai", "api_key", fallback="").strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        raw = raw[1:-1].strip()
    return raw


def _seed_minimal_v0_prompt() -> str:
    # Treat minimal as v0 baseline.
    return (
        'You are the tactical planner for a hex turn-based game. Respond with one JSON object only: '
        '{"opponent_prediction":"string","reasoning_summary":"string","actions":[{"unit_id":NUMBER,"action_key":"string","target_cell":[q,r]}]}. '
        "Choose exactly one action per AI unit from ai_units[].legal_options[] using action_key + target_cell. "
        "Never invent action keys or target cells. "
        "Use immediate value first: prefer options that deal guaranteed damage now (expected_visible_hits_if_targeted > 0). "
        "Otherwise prefer safe progress: lower pred_damage_at_end (or incoming_damage_if_enemies_hold_and_shoot_end when pred_* missing), "
        "then lower distance to enemies. Keep reasoning_summary brief."
    )


def _load_or_init_version_registry(project_root: pathlib.Path) -> dict[str, Any]:
    reg_path = project_root / VERSION_REGISTRY_REL
    if reg_path.exists():
        try:
            obj = _load_json(reg_path)
            if isinstance(obj, dict) and isinstance(obj.get("versions", []), list):
                return obj
        except Exception:
            pass
    artifacts_root = project_root / VERSION_ARTIFACTS_REL
    artifacts_root.mkdir(parents=True, exist_ok=True)
    v0_prompt_path = artifacts_root / "v0_prompt.txt"
    _write_text(v0_prompt_path, _seed_minimal_v0_prompt())
    reg = {
        "latest_version": 0,
        "versions": [
            {
                "version": 0,
                "name": "minimal_v0",
                "prompt_file": str(v0_prompt_path),
                "payload_mutation_file": "",
                "source": "seed_minimal_v0",
                "created_at": dt.datetime.utcnow().isoformat() + "Z",
            }
        ],
    }
    _write_json(reg_path, reg)
    return reg


def _select_start_version_entry(registry: dict[str, Any], start_version: int | None) -> dict[str, Any]:
    versions = registry.get("versions", [])
    if not isinstance(versions, list) or not versions:
        return {}
    if start_version is None:
        latest = int(registry.get("latest_version", 0))
        for v in versions:
            if isinstance(v, dict) and int(v.get("version", -1)) == latest:
                return v
    else:
        for v in versions:
            if isinstance(v, dict) and int(v.get("version", -1)) == start_version:
                return v
    # fallback to max available version
    best: dict[str, Any] | None = None
    for v in versions:
        if not isinstance(v, dict):
            continue
        if best is None or int(v.get("version", -1)) > int(best.get("version", -1)):
            best = v
    return best or {}


def _promote_new_version(
    project_root: pathlib.Path,
    registry: dict[str, Any],
    session_id: str,
    source_prompt_file: str,
    source_payload_mutation_file: str,
) -> dict[str, Any]:
    artifacts_root = project_root / VERSION_ARTIFACTS_REL
    artifacts_root.mkdir(parents=True, exist_ok=True)
    latest = int(registry.get("latest_version", 0))
    new_version = latest + 1

    dst_prompt = artifacts_root / f"v{new_version}_prompt.txt"
    if source_prompt_file and pathlib.Path(source_prompt_file).exists():
        shutil.copyfile(source_prompt_file, dst_prompt)
    else:
        # fallback: carry forward latest prompt file if present
        prev = _select_start_version_entry(registry, latest)
        prev_prompt = str(prev.get("prompt_file", "")).strip()
        if prev_prompt and pathlib.Path(prev_prompt).exists():
            shutil.copyfile(prev_prompt, dst_prompt)
        else:
            _write_text(dst_prompt, _seed_minimal_v0_prompt())

    dst_payload = ""
    if source_payload_mutation_file and pathlib.Path(source_payload_mutation_file).exists():
        dst_payload_path = artifacts_root / f"v{new_version}_payload_mutation.json"
        shutil.copyfile(source_payload_mutation_file, dst_payload_path)
        dst_payload = str(dst_payload_path)

    entry = {
        "version": new_version,
        "name": f"auto_v{new_version}",
        "prompt_file": str(dst_prompt),
        "payload_mutation_file": dst_payload,
        "source": f"session:{session_id}",
        "created_at": dt.datetime.utcnow().isoformat() + "Z",
    }
    versions = registry.get("versions", [])
    if not isinstance(versions, list):
        versions = []
    versions.append(entry)
    registry["versions"] = versions
    registry["latest_version"] = new_version
    _write_json(project_root / VERSION_REGISTRY_REL, registry)
    return entry


def _run_eval_suite(
    project_root: pathlib.Path,
    run_id: str,
    thinking_level: str,
    model_override: str,
    planning_prompt_version: str,
    prompt_version: str,
    eval_set_version: str,
    custom_system_prompt_file: str,
    payload_profile: str,
    payload_mutation_file: str,
    use_two_call_planning: str,
    jobs: int,
    planning_max_tokens: int,
) -> tuple[int, pathlib.Path]:
    cmd = [
        "python3",
        "tools/evals/run_eval_suite.py",
        "--mode",
        "live_llm",
        "--run-id",
        run_id,
        "--thinking-level",
        thinking_level,
        "--model",
        model_override,
        "--planning-prompt-version",
        planning_prompt_version,
        "--prompt-version",
        prompt_version,
        "--eval-set-version",
        eval_set_version,
        "--jobs",
        str(max(1, int(jobs))),
    ]
    if custom_system_prompt_file:
        cmd += ["--custom-system-prompt-file", custom_system_prompt_file]
    if payload_profile:
        cmd += ["--payload-profile", payload_profile]
    if payload_mutation_file:
        cmd += ["--payload-mutation-file", payload_mutation_file]
    if use_two_call_planning:
        cmd += ["--use-two-call-planning", use_two_call_planning]
    if planning_max_tokens > 0:
        cmd += ["--planning-max-tokens", str(int(planning_max_tokens))]
    proc = subprocess.run(cmd, cwd=str(project_root), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(proc.stdout)
    return proc.returncode, project_root / "tools" / "evals" / "runs" / run_id / "summary.json"


def _failed_cases_for_run(project_root: pathlib.Path, run_id: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    cases_dir = project_root / "tools" / "evals" / "runs" / run_id / "cases"
    if not cases_dir.exists():
        return out
    for f in sorted(cases_dir.glob("*.json")):
        try:
            d = _load_json(f)
        except Exception:
            continue
        if not bool(d.get("pass", False)):
            d["_file"] = f.name
            out.append(d)
    return out


def _extract_prompt_from_run(project_root: pathlib.Path, run_id: str) -> str:
    cases_dir = project_root / "tools" / "evals" / "runs" / run_id / "cases"
    if not cases_dir.exists():
        return ""
    for f in sorted(cases_dir.glob("*.json")):
        try:
            d = _load_json(f)
        except Exception:
            continue
        llm = d.get("llm", {})
        if not isinstance(llm, dict):
            continue
        pd = llm.get("prompt_debug", {})
        if isinstance(pd, dict):
            p = str(pd.get("system_prompt", "")).strip()
            if p:
                return p
    return ""


def _optimizer_messages(current_prompt: str, failed_cases: list[dict[str, Any]]) -> list[dict[str, str]]:
    compact_failures = []
    for c in failed_cases[:8]:
        llm = c.get("llm", {}) if isinstance(c, dict) else {}
        raw = ""
        if isinstance(llm, dict):
            raw = str(llm.get("raw", ""))[:700]
        compact_failures.append(
            {
                "case_id": str(c.get("case_id", "")),
                "intent": str(c.get("intent", "")),
                "reason": str(c.get("reason", "")),
                "raw_response_excerpt": raw,
            }
        )

    system = (
        "You optimize tactical-planning system prompts for a hex strategy game eval harness.\n"
        "Return STRICT JSON only with shape: "
        '{"new_system_prompt":"string","payload_mutation_spec":{"remove_paths":[],"set_values":{},"copy_paths":[]},"suggested_snapshot_fields_to_add":[{"field_name":"string","where":"string","why":"string","example_value":"any"}],"rationale":"string","expected_fix":"string"}.\n'
        "Constraints for new_system_prompt:\n"
        "- single-call planner prompt (no two-step references)\n"
        "- concise (<2200 chars)\n"
        "- preserve strict JSON output contract for actions using action_key + target_cell on each action\n"
        "- add explicit guidance to target predicted landing cells for fast movers when relevant\n"
        "- prefer deterministic instructions over prose\n"
        "Constraints for payload_mutation_spec:\n"
        "- keep fields JSON-safe\n"
        "- use remove_paths to drop noisy fields\n"
        "- use set_values to add constant context fields\n"
        "- use copy_paths with {from,to} to duplicate helpful fields into concise locations\n"
        "- dot paths supported, [] wildcard allowed for arrays\n"
        "Constraints for suggested_snapshot_fields_to_add:\n"
        "- only recommend truly new engine-computed fields not currently present\n"
        "- keep list short (0-5)\n"
        "- include concrete placement path in 'where' and brief why"
    )
    user = json.dumps(
        {
            "task": "Improve this system prompt using the failed evals.",
            "current_system_prompt": current_prompt,
            "failed_cases": compact_failures,
        },
        indent=2,
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def _extract_responses_output_text(data: dict[str, Any]) -> str:
    direct = str(data.get("output_text", "")).strip()
    if direct:
        return direct
    output = data.get("output", [])
    if isinstance(output, list):
        for item in output:
            if not isinstance(item, dict):
                continue
            content = item.get("content", [])
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if str(block.get("type", "")) == "output_text":
                    text = str(block.get("text", "")).strip()
                    if text:
                        return text
    return ""


def _call_optimizer_responses(
    base_url: str,
    api_key: str,
    model: str,
    messages: list[dict[str, str]],
    reasoning_effort: str,
    timeout_seconds: int = 120,
) -> str:
    url = base_url.rstrip("/") + "/responses"
    input_items: list[dict[str, Any]] = []
    for m in messages:
        input_items.append(
            {
                "role": m["role"],
                "content": [{"type": "input_text", "text": m["content"]}],
            }
        )
    payload = json.dumps(
        {
            "model": model,
            "reasoning": {"effort": reasoning_effort},
            "input": input_items,
            "text": {"format": {"type": "json_object"}},
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=max(30, int(timeout_seconds))) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"optimizer HTTP {e.code}: {body[:500]}") from e
    except Exception as e:
        raise RuntimeError(f"optimizer request failed: {e}") from e
    content = _extract_responses_output_text(data)
    if not content:
        raise RuntimeError("optimizer returned empty content")
    return content


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt-version", default="p_current_settings")
    parser.add_argument("--eval-set-version", default="eval_v001")
    parser.add_argument("--thinking-level", default="low")
    parser.add_argument("--model", default="gpt-5.4-mini")
    parser.add_argument("--planning-prompt-version", default="minimal")
    parser.add_argument("--payload-profile", default="baseline")
    parser.add_argument("--use-two-call-planning", default="")
    parser.add_argument("--start-version", default="")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--target-avg-final-score", type=float, default=0.9)
    parser.add_argument("--max-iters", type=int, default=4)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--optimizer-model", default="gpt-5.4")
    parser.add_argument("--optimizer-thinking-level", default="medium")
    parser.add_argument("--optimizer-base-url", default="https://api.openai.com/v1")
    parser.add_argument(
        "--planning-max-tokens",
        type=int,
        default=0,
        help="Passed to run_eval_suite; raises Responses API max_output_tokens (needed for xhigh reasoning). 0 = Godot default.",
    )
    parser.add_argument(
        "--optimizer-timeout-seconds",
        type=int,
        default=120,
        help="HTTP read timeout for the optimizer Responses API call.",
    )
    args = parser.parse_args()

    project_root = pathlib.Path(__file__).resolve().parents[2]
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        api_key = _read_api_key_from_llm_settings(project_root)
    if not api_key:
        print("OPENAI_API_KEY is required (env or llm_ai_settings.cfg).", file=sys.stderr)
        return 2

    registry = _load_or_init_version_registry(project_root)
    start_version: int | None = None
    if args.start_version.strip():
        try:
            start_version = int(args.start_version.strip())
        except Exception:
            print("--start-version must be an integer if provided.", file=sys.stderr)
            return 7
    start_entry = _select_start_version_entry(registry, start_version)
    if not start_entry:
        print("Could not resolve start prompt version.", file=sys.stderr)
        return 8
    session_id = args.session_id.strip() or f"self_evolve_{_utc_stamp()}"
    session_root = project_root / "tools" / "evals" / "self_evolve" / session_id
    prompts_dir = session_root / "prompts"
    _write_json(
        session_root / "session_meta.json",
        {
            "session_id": session_id,
            "created_at": dt.datetime.utcnow().isoformat() + "Z",
            "target_avg_final_score": args.target_avg_final_score,
            "max_iters": args.max_iters,
            "planning_prompt_version": args.planning_prompt_version,
            "payload_profile": args.payload_profile,
            "use_two_call_planning": args.use_two_call_planning,
            "start_version": int(start_entry.get("version", 0)),
            "thinking_level": args.thinking_level,
            "optimizer_model": args.optimizer_model,
            "optimizer_thinking_level": args.optimizer_thinking_level,
            "planning_max_tokens": int(args.planning_max_tokens),
            "optimizer_timeout_seconds": int(args.optimizer_timeout_seconds),
        },
    )

    custom_prompt_file = str(start_entry.get("prompt_file", "")).strip()
    payload_mutation_file = str(start_entry.get("payload_mutation_file", "")).strip()
    current_prompt = ""
    history: list[dict[str, Any]] = []
    all_snapshot_field_suggestions: list[dict[str, Any]] = []

    for i in range(1, max(1, args.max_iters) + 1):
        run_id = f"{session_id}_iter{i:02d}"
        code, summary_path = _run_eval_suite(
            project_root=project_root,
            run_id=run_id,
            thinking_level=args.thinking_level,
            model_override=args.model,
            planning_prompt_version=args.planning_prompt_version,
            prompt_version=args.prompt_version,
            eval_set_version=args.eval_set_version,
            custom_system_prompt_file=custom_prompt_file,
            payload_profile=args.payload_profile,
            payload_mutation_file=payload_mutation_file,
            use_two_call_planning=args.use_two_call_planning,
            jobs=args.jobs,
            planning_max_tokens=int(args.planning_max_tokens),
        )
        if not summary_path.exists():
            print(f"missing summary for run {run_id}", file=sys.stderr)
            return 3
        summary = _load_json(summary_path)
        pass_rate = float(summary.get("pass_rate", 0.0))
        avg_final_score = float(summary.get("avg_final_score", 0.0))
        failed = _failed_cases_for_run(project_root, run_id)
        current_prompt = _extract_prompt_from_run(project_root, run_id) or current_prompt

        iter_entry: dict[str, Any] = {
            "iter": i,
            "run_id": run_id,
            "exit_code": code,
            "pass_rate": pass_rate,
            "avg_final_score": avg_final_score,
            "fail_count": len(failed),
            "custom_prompt_file": custom_prompt_file,
            "payload_mutation_file": payload_mutation_file,
        }
        history.append(iter_entry)
        _write_json(session_root / "history.json", history)

        if avg_final_score > args.target_avg_final_score:
            print(
                "Target reached at iter %d: avg_final_score=%.3f (> %.3f)"
                % (i, avg_final_score, args.target_avg_final_score)
            )
            promoted = _promote_new_version(
                project_root=project_root,
                registry=registry,
                session_id=session_id,
                source_prompt_file=custom_prompt_file,
                source_payload_mutation_file=payload_mutation_file,
            )
            _write_json(
                session_root / "snapshot_field_suggestions.json",
                {"suggested_snapshot_fields_to_add": all_snapshot_field_suggestions},
            )
            _write_json(
                session_root / "result.json",
                {
                    "status": "target_reached",
                    "reason": "avg_final_score",
                    "history": history,
                    "promoted_version": promoted,
                },
            )
            return 0

        if not failed:
            print("No failed cases but target not met; stopping.", file=sys.stderr)
            _write_json(
                session_root / "snapshot_field_suggestions.json",
                {"suggested_snapshot_fields_to_add": all_snapshot_field_suggestions},
            )
            _write_json(session_root / "result.json", {"status": "stopped_no_failures", "history": history})
            return 4

        if not current_prompt.strip():
            print("Could not read current system prompt from run artifacts.", file=sys.stderr)
            _write_json(
                session_root / "snapshot_field_suggestions.json",
                {"suggested_snapshot_fields_to_add": all_snapshot_field_suggestions},
            )
            return 5

        messages = _optimizer_messages(current_prompt=current_prompt, failed_cases=failed)
        raw_optimizer = _call_optimizer_responses(
            base_url=args.optimizer_base_url,
            api_key=api_key,
            model=args.optimizer_model,
            messages=messages,
            reasoning_effort=args.optimizer_thinking_level,
            timeout_seconds=int(args.optimizer_timeout_seconds),
        )
        parsed = json.loads(raw_optimizer)
        new_prompt = str(parsed.get("new_system_prompt", "")).strip()
        if not new_prompt:
            print("Optimizer did not return new_system_prompt.", file=sys.stderr)
            _write_json(
                session_root / "snapshot_field_suggestions.json",
                {"suggested_snapshot_fields_to_add": all_snapshot_field_suggestions},
            )
            return 6
        prompt_file = prompts_dir / f"iter{i:02d}_prompt.txt"
        _write_text(prompt_file, new_prompt)
        _write_json(
            prompts_dir / f"iter{i:02d}_optimizer.json",
            {"raw": raw_optimizer, "parsed": parsed, "failed_cases": failed},
        )
        suggested_fields_v = parsed.get("suggested_snapshot_fields_to_add", [])
        if isinstance(suggested_fields_v, list):
            for sf in suggested_fields_v:
                if isinstance(sf, dict):
                    row = dict(sf)
                    row["iter"] = i
                    row["run_id"] = run_id
                    all_snapshot_field_suggestions.append(row)
            _write_json(
                prompts_dir / f"iter{i:02d}_snapshot_field_suggestions.json",
                {"suggested_snapshot_fields_to_add": suggested_fields_v},
            )
        var_payload_spec = parsed.get("payload_mutation_spec", {})
        if isinstance(var_payload_spec, dict):
            payload_spec_path = prompts_dir / f"iter{i:02d}_payload_mutation.json"
            _write_json(payload_spec_path, var_payload_spec)
            payload_mutation_file = str(payload_spec_path)
        custom_prompt_file = str(prompt_file)
        current_prompt = new_prompt

    _write_json(
        session_root / "snapshot_field_suggestions.json",
        {"suggested_snapshot_fields_to_add": all_snapshot_field_suggestions},
    )
    _write_json(session_root / "result.json", {"status": "max_iters_reached", "history": history})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

