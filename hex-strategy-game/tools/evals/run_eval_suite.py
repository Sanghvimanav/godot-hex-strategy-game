#!/usr/bin/env python3
"""
Run all planning eval cases, store per-case artifacts, and append leaderboard row.

Example:
  cd hex-strategy-game
  python3 tools/evals/run_eval_suite.py --mode live_llm --prompt-version p_v001 --eval-set-version eval_v001
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import signal
import subprocess
import sys
from typing import Any


MODEL_PRICING_PER_MTOK_USD: dict[str, dict[str, float]] = {
    # Update these estimates as model pricing changes.
    "gpt-5.4": {"input": 1.25, "output": 10.0},
    "gpt-5.4-mini": {"input": 0.25, "output": 2.0},
    "gpt-5.4-nano": {"input": 0.25, "output": 2.0},
    "gpt-5.5": {"input": 1.25, "output": 10.0},
    "gpt-5.5-mini": {"input": 0.25, "output": 2.0},
    "gpt-5": {"input": 1.25, "output": 10.0},
    "gpt-5-mini": {"input": 0.25, "output": 2.0},
    "gpt-4.1": {"input": 2.0, "output": 8.0},
    "gpt-4.1-mini": {"input": 0.4, "output": 1.6},
}


def _now_stamp() -> str:
    return dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def _load_json(path: pathlib.Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _write_json(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def _git_sha(repo_root: pathlib.Path) -> str:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=str(repo_root), stderr=subprocess.DEVNULL, text=True
        ).strip()
        return out
    except Exception:
        return ""


def _safe_name(s: str) -> str:
    out = "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in s.strip())
    return out or "run"


def _pricing_for_model(model_name: str) -> dict[str, float]:
    return MODEL_PRICING_PER_MTOK_USD.get(model_name.strip(), {"input": 0.0, "output": 0.0})


def _estimate_usage_cost_usd(usage: dict[str, Any], model_name: str) -> float:
    if not isinstance(usage, dict):
        return 0.0
    rates = _pricing_for_model(model_name)
    input_tokens = int(usage.get("input_tokens", 0))
    output_tokens = int(usage.get("output_tokens", 0))
    in_cost = (float(input_tokens) / 1_000_000.0) * float(rates.get("input", 0.0))
    out_cost = (float(output_tokens) / 1_000_000.0) * float(rates.get("output", 0.0))
    return in_cost + out_cost


def _case_turn_count(case: dict[str, Any]) -> int:
    try:
        turns = int(case.get("turn_count", 1))
    except Exception:
        turns = 1
    return max(1, turns)


def _run_single_case(
    *,
    project_root: pathlib.Path,
    run_id: str,
    mode: str,
    prompt_version: str,
    eval_set_version: str,
    thinking_level: str,
    model_override: str,
    notes: str,
    planning_prompt_version: str,
    custom_system_prompt_file: str,
    payload_profile: str,
    payload_mutation_file: str,
    use_two_call_planning: str,
    planning_max_tokens: int,
    case_id: str,
    out_file: pathlib.Path,
    case_timeout_seconds: int,
) -> dict[str, Any]:
    cmd = [
        "./tools/run_planning_eval.sh",
        f"--case={case_id}",
        f"--mode={mode}",
        f"--out={str(out_file)}",
        f"--run_id={run_id}",
        f"--prompt_version={prompt_version}",
        f"--eval_set_version={eval_set_version}",
    ]
    if thinking_level:
        cmd.append(f"--thinking_level={thinking_level}")
    if model_override:
        cmd.append(f"--model={model_override}")
    if notes:
        cmd.append(f"--notes={notes}")
    if planning_prompt_version:
        cmd.append(f"--planning_prompt_version={planning_prompt_version}")
    if custom_system_prompt_file:
        cmd.append(f"--custom_system_prompt_file={custom_system_prompt_file}")
    if payload_profile:
        cmd.append(f"--payload_profile={payload_profile}")
    if payload_mutation_file:
        cmd.append(f"--payload_mutation_file={payload_mutation_file}")
    if use_two_call_planning:
        cmd.append(f"--use_two_call_planning={use_two_call_planning}")
    if planning_max_tokens > 0:
        cmd.append(f"--planning_max_tokens={int(planning_max_tokens)}")

    timed_out = False
    runner_exit_code = 0
    stdout_text = ""
    proc = subprocess.Popen(
        cmd,
        cwd=str(project_root),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        preexec_fn=os.setsid,
    )
    try:
        out, _ = proc.communicate(timeout=max(1, int(case_timeout_seconds)))
        stdout_text = out or ""
        runner_exit_code = int(proc.returncode or 0)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            proc.kill()
        out, _ = proc.communicate()
        stdout_text = out or ""
        runner_exit_code = 124

    result_obj: dict[str, Any]
    if out_file.exists():
        result_obj = _load_json(out_file)
    else:
        reason = f"missing_output_file (exit={runner_exit_code})"
        if timed_out:
            reason = f"case_timeout_after_{int(case_timeout_seconds)}s"
        result_obj = {
            "case_id": case_id,
            "pass": False,
            "reason": reason,
        }
    result_obj["runner_exit_code"] = runner_exit_code
    if timed_out:
        result_obj["runner_timed_out"] = True
        result_obj["runner_timeout_seconds"] = int(case_timeout_seconds)
    if stdout_text.strip():
        result_obj["runner_stdout_tail"] = stdout_text[-4000:]
        _write_json(out_file, result_obj)
    return {"case_id": case_id, "result_obj": result_obj, "runner_exit_code": runner_exit_code}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="live_llm", choices=["live_llm", "snapshot"])
    parser.add_argument("--prompt-version", default="")
    parser.add_argument("--eval-set-version", default="")
    parser.add_argument("--planning-prompt-version", default="")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--thinking-level", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--notes", default="")
    parser.add_argument("--manifest", default="")
    parser.add_argument("--custom-system-prompt-file", default="")
    parser.add_argument("--payload-profile", default="")
    parser.add_argument("--payload-mutation-file", default="")
    parser.add_argument("--use-two-call-planning", default="")
    parser.add_argument("--cases-file", default="tools/evals/planning_eval_cases.json")
    parser.add_argument("--leaderboard-file", default="tools/evals/leaderboard.jsonl")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--case-timeout-seconds", type=int, default=450)
    parser.add_argument(
        "--planning-max-tokens",
        type=int,
        default=0,
        help="Override max output tokens for planning (Responses API includes reasoning). 0 = use Godot llm_ai_settings.",
    )
    args = parser.parse_args()

    project_root = pathlib.Path(__file__).resolve().parents[2]
    manifest: dict[str, Any] = {}
    if args.manifest:
        mpath = pathlib.Path(args.manifest)
        if not mpath.is_absolute():
            mpath = project_root / mpath
        if mpath.exists():
            manifest = _load_json(mpath)
    prompt_version = args.prompt_version or str(manifest.get("prompt_version", "p_v001"))
    eval_set_version = args.eval_set_version or str(manifest.get("eval_set_version", "eval_v001"))
    thinking_level = args.thinking_level or str(manifest.get("thinking_level", ""))
    model_override = args.model or str(manifest.get("model", ""))
    notes = args.notes or str(manifest.get("notes", ""))
    planning_prompt_version = args.planning_prompt_version or str(manifest.get("planning_prompt_version", ""))
    custom_system_prompt_file = args.custom_system_prompt_file or str(manifest.get("custom_system_prompt_file", ""))
    payload_profile = args.payload_profile or str(manifest.get("payload_profile", "baseline"))
    payload_mutation_file = args.payload_mutation_file or str(manifest.get("payload_mutation_file", ""))
    use_two_call_planning = args.use_two_call_planning or str(
        manifest.get("use_two_call_planning", "")
    )
    planning_max_tokens = int(args.planning_max_tokens or manifest.get("planning_max_tokens", 0) or 0)

    run_id = args.run_id.strip() or f"{_now_stamp()}_{_safe_name(prompt_version)}"
    runs_root = project_root / "tools" / "evals" / "runs" / run_id
    cases_out_dir = runs_root / "cases"
    cases_out_dir.mkdir(parents=True, exist_ok=True)

    cases_doc = _load_json(project_root / args.cases_file)
    cases = cases_doc.get("cases", [])
    if not isinstance(cases, list) or not cases:
        print("No eval cases found.", file=sys.stderr)
        return 1
    jobs = max(1, int(args.jobs))

    run_meta = {
        "run_id": run_id,
        "created_at": dt.datetime.utcnow().isoformat() + "Z",
        "mode": args.mode,
        "prompt_version": prompt_version,
        "eval_set_version": eval_set_version,
        "thinking_level": thinking_level,
        "model_override": model_override,
        "notes": notes,
        "planning_prompt_version": planning_prompt_version,
        "custom_system_prompt_file": custom_system_prompt_file,
        "payload_profile": payload_profile,
        "payload_mutation_file": payload_mutation_file,
        "use_two_call_planning": use_two_call_planning,
        "planning_max_tokens": planning_max_tokens,
        "git_sha": _git_sha(project_root),
        "manifest": args.manifest,
    }
    _write_json(runs_root / "run_meta.json", run_meta)

    per_case_results: list[dict[str, Any]] = []
    pass_count = 0
    failed_case_ids: list[str] = []
    failed_case_reasons: dict[str, str] = {}
    final_scores: list[float] = []
    speed_scores_on_pass: list[float] = []
    total_tokens = 0
    total_estimated_cost_usd = 0.0
    resolved_settings: dict[str, Any] = {}

    case_ids_in_order: list[str] = []
    out_file_by_case_id: dict[str, pathlib.Path] = {}
    case_turns_by_case_id: dict[str, int] = {}
    for case in cases:
        case_id = str(case.get("case_id", "")).strip()
        if not case_id:
            continue
        case_ids_in_order.append(case_id)
        if isinstance(case, dict):
            case_turns_by_case_id[case_id] = _case_turn_count(case)
        else:
            case_turns_by_case_id[case_id] = 1
        out_file = cases_out_dir / f"{case_id}.json"
        out_file_by_case_id[case_id] = out_file

    raw_results_by_case_id: dict[str, dict[str, Any]] = {}
    if jobs == 1:
        for case_id in case_ids_in_order:
            out_file = out_file_by_case_id[case_id]
            raw = _run_single_case(
                project_root=project_root,
                run_id=run_id,
                mode=args.mode,
                prompt_version=prompt_version,
                eval_set_version=eval_set_version,
                thinking_level=thinking_level,
                model_override=model_override,
                notes=notes,
                planning_prompt_version=planning_prompt_version,
                custom_system_prompt_file=custom_system_prompt_file,
                payload_profile=payload_profile,
                payload_mutation_file=payload_mutation_file,
                use_two_call_planning=use_two_call_planning,
                planning_max_tokens=planning_max_tokens,
                case_id=case_id,
                out_file=out_file,
                case_timeout_seconds=args.case_timeout_seconds,
            )
            raw_results_by_case_id[case_id] = raw
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            future_by_case_id: dict[str, concurrent.futures.Future[dict[str, Any]]] = {}
            for case_id in case_ids_in_order:
                out_file = out_file_by_case_id[case_id]
                future_by_case_id[case_id] = executor.submit(
                    _run_single_case,
                    project_root=project_root,
                    run_id=run_id,
                    mode=args.mode,
                    prompt_version=prompt_version,
                    eval_set_version=eval_set_version,
                    thinking_level=thinking_level,
                    model_override=model_override,
                    notes=notes,
                    planning_prompt_version=planning_prompt_version,
                    custom_system_prompt_file=custom_system_prompt_file,
                    payload_profile=payload_profile,
                    payload_mutation_file=payload_mutation_file,
                    use_two_call_planning=use_two_call_planning,
                    planning_max_tokens=planning_max_tokens,
                    case_id=case_id,
                    out_file=out_file,
                    case_timeout_seconds=args.case_timeout_seconds,
                )
            for case_id, future in future_by_case_id.items():
                raw_results_by_case_id[case_id] = future.result()

    for case_id in case_ids_in_order:
        out_file = out_file_by_case_id[case_id]
        raw = raw_results_by_case_id[case_id]
        result_obj = raw.get("result_obj", {}) if isinstance(raw, dict) else {}
        if not isinstance(result_obj, dict):
            result_obj = {
                "case_id": case_id,
                "pass": False,
                "reason": "invalid_runner_result_object",
                "runner_exit_code": int(raw.get("runner_exit_code", -1)) if isinstance(raw, dict) else -1,
            }
        per_case_results.append(result_obj)

        if bool(result_obj.get("pass", False)):
            pass_count += 1
        else:
            failed_id = str(result_obj.get("case_id", case_id))
            failed_case_ids.append(failed_id)
            failed_case_reasons[failed_id] = str(result_obj.get("reason", "unknown"))

        grading = result_obj.get("grading", {}) if isinstance(result_obj, dict) else {}
        if isinstance(grading, dict):
            try:
                final_scores.append(float(grading.get("final_score", 0.0)))
            except Exception:
                pass
            if bool(result_obj.get("pass", False)):
                try:
                    speed_scores_on_pass.append(float(grading.get("speed_score", 0.0)))
                except Exception:
                    pass

        llm = result_obj.get("llm", {}) if isinstance(result_obj, dict) else {}
        if isinstance(llm, dict):
            if args.mode == "live_llm" and not resolved_settings:
                resolved_settings = {
                    "model": str(llm.get("model", "")),
                    "reasoning_effort": str(llm.get("reasoning_effort", "")),
                    "planning_prompt_version": str(llm.get("planning_prompt_version", "")),
                    "use_responses_api": bool(llm.get("use_responses_api", False)),
                    "use_two_call_planning": bool(llm.get("use_two_call_planning", False)),
                    "planning_max_tokens": int(llm.get("planning_max_tokens", 0)),
                    "base_url": str(llm.get("base_url", "")),
                }
            model_for_cost = str(llm.get("model", "")) or model_override
            case_cost_usd = 0.0
            usage = llm.get("usage", {})
            if isinstance(usage, dict):
                total_tokens += int(usage.get("total_tokens", 0))
                case_cost_usd += _estimate_usage_cost_usd(usage, model_for_cost)
            pred_usage = llm.get("prediction_usage", {})
            if isinstance(pred_usage, dict):
                total_tokens += int(pred_usage.get("total_tokens", 0))
                case_cost_usd += _estimate_usage_cost_usd(pred_usage, model_for_cost)
            llm["estimated_cost_usd"] = round(case_cost_usd, 8)
            result_obj["estimated_cost_usd"] = round(case_cost_usd, 8)
            total_estimated_cost_usd += case_cost_usd
            _write_json(out_file, result_obj)

    n = len(per_case_results)
    total_eval_turns = sum(case_turns_by_case_id.get(case_id, 1) for case_id in case_ids_in_order)
    estimated_cost_usd_per_eval_turn = (
        (total_estimated_cost_usd / float(total_eval_turns)) if total_eval_turns > 0 else 0.0
    )
    effective_model_version = model_override or str(resolved_settings.get("model", ""))
    effective_thinking_level = thinking_level or str(resolved_settings.get("reasoning_effort", ""))
    effective_planning_prompt_version = planning_prompt_version or str(
        resolved_settings.get("planning_prompt_version", "")
    )
    effective_use_responses_api = bool(resolved_settings.get("use_responses_api", False))
    effective_use_two_call_planning = bool(resolved_settings.get("use_two_call_planning", False))
    effective_planning_max_tokens = int(resolved_settings.get("planning_max_tokens", 0))
    effective_base_url = str(resolved_settings.get("base_url", ""))

    run_meta["model_version"] = effective_model_version
    run_meta["thinking_level"] = effective_thinking_level
    run_meta["planning_prompt_version"] = effective_planning_prompt_version
    run_meta["use_responses_api"] = effective_use_responses_api
    run_meta["use_two_call_planning"] = effective_use_two_call_planning
    run_meta["planning_max_tokens"] = effective_planning_max_tokens
    run_meta["base_url"] = effective_base_url
    _write_json(runs_root / "run_meta.json", run_meta)

    summary = {
        "run_meta": run_meta,
        "total_cases": n,
        "pass_cases": pass_count,
        "fail_cases": n - pass_count,
        "failed_case_ids": failed_case_ids,
        "failed_case_reasons": failed_case_reasons,
        "pass_rate": (float(pass_count) / float(n)) if n else 0.0,
        "avg_final_score": (sum(final_scores) / len(final_scores)) if final_scores else 0.0,
        "avg_speed_on_pass": (sum(speed_scores_on_pass) / len(speed_scores_on_pass)) if speed_scores_on_pass else 0.0,
        "total_tokens": total_tokens,
        "total_eval_turns": total_eval_turns,
        "estimated_cost_usd": round(total_estimated_cost_usd, 8),
        "estimated_cost_usd_per_eval_turn": round(estimated_cost_usd_per_eval_turn, 8),
    }
    _write_json(runs_root / "summary.json", summary)

    leaderboard_row = {
        "run_id": run_id,
        "created_at": run_meta["created_at"],
        "mode": args.mode,
        "prompt_version": prompt_version,
        "eval_set_version": eval_set_version,
        "model_version": effective_model_version,
        "thinking_level": effective_thinking_level,
        "planning_prompt_version": effective_planning_prompt_version,
        "payload_profile": payload_profile,
        "payload_mutation_file": payload_mutation_file,
        "use_responses_api": effective_use_responses_api,
        "use_two_call_planning": effective_use_two_call_planning,
        "git_sha": run_meta["git_sha"],
        "pass_rate": summary["pass_rate"],
        "avg_final_score": summary["avg_final_score"],
        "avg_speed_on_pass": summary["avg_speed_on_pass"],
        "total_tokens": total_tokens,
        "estimated_cost_usd_per_eval_turn": round(estimated_cost_usd_per_eval_turn, 8),
        "total_cases": n,
        "pass_cases": pass_count,
    }
    leaderboard_path = project_root / args.leaderboard_file
    leaderboard_path.parent.mkdir(parents=True, exist_ok=True)
    with leaderboard_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(leaderboard_row) + "\n")

    print(json.dumps(summary, indent=2))
    return 0 if pass_count == n else 2


if __name__ == "__main__":
    raise SystemExit(main())

