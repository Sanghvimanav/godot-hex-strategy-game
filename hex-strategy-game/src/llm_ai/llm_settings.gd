class_name LlmAiSettings
extends RefCounted
## BYOK settings persisted under user://. Never log api_key (see specs/llm-self-learning-ai.md §12).

const SECTION = "llm_ai"
const USER_CONFIG_PATH = "user://llm_ai_settings.cfg"

var base_url: String = "https://api.openai.com/v1"
var model: String = ""
var api_key: String = ""
## Max completion tokens (chat) or max_output_tokens (Responses API; includes hidden reasoning tokens).
var planning_max_tokens: int = 2048
## Use POST /v1/responses with reasoning.effort (OpenAI thinking / GPT-5 family). Chat Completions does not support reasoning effort.
var use_responses_api: bool = false
## For Responses API: none, minimal, low, medium, high, xhigh (model-dependent).
var reasoning_effort: String = "medium"
## Prompt profile for planner: "legacy" (current full prompt) or "minimal" (reset baseline).
var planning_prompt_version: String = "legacy"
## Experimental: run planning in two passes (enemy prediction call, then action selection call).
var use_two_call_planning: bool = false
## When true, each LLM planning request writes the full user JSON snapshot to user://llm_planning_logs/ (no secrets).
var log_planning_payloads: bool = true


func load_from_disk() -> void:
	var cf := ConfigFile.new()
	if cf.load(USER_CONFIG_PATH) != OK:
		return
	base_url = str(cf.get_value(SECTION, "base_url", base_url))
	model = str(cf.get_value(SECTION, "model", model))
	api_key = str(cf.get_value(SECTION, "api_key", api_key))
	planning_max_tokens = int(cf.get_value(SECTION, "planning_max_tokens", planning_max_tokens))
	planning_max_tokens = clampi(planning_max_tokens, 256, 65536)
	use_responses_api = bool(cf.get_value(SECTION, "use_responses_api", use_responses_api))
	reasoning_effort = str(cf.get_value(SECTION, "reasoning_effort", reasoning_effort))
	planning_prompt_version = str(cf.get_value(SECTION, "planning_prompt_version", planning_prompt_version)).strip_edges().to_lower()
	if planning_prompt_version.is_empty():
		planning_prompt_version = "legacy"
	use_two_call_planning = bool(cf.get_value(SECTION, "use_two_call_planning", use_two_call_planning))
	log_planning_payloads = bool(cf.get_value(SECTION, "log_planning_payloads", log_planning_payloads))


func save_to_disk() -> Error:
	var cf := ConfigFile.new()
	cf.set_value(SECTION, "base_url", base_url.strip_edges())
	cf.set_value(SECTION, "model", model.strip_edges())
	cf.set_value(SECTION, "api_key", api_key)
	cf.set_value(SECTION, "planning_max_tokens", clampi(planning_max_tokens, 256, 65536))
	cf.set_value(SECTION, "use_responses_api", use_responses_api)
	cf.set_value(SECTION, "reasoning_effort", reasoning_effort.strip_edges())
	cf.set_value(SECTION, "planning_prompt_version", planning_prompt_version.strip_edges().to_lower())
	cf.set_value(SECTION, "use_two_call_planning", use_two_call_planning)
	cf.set_value(SECTION, "log_planning_payloads", log_planning_payloads)
	return cf.save(USER_CONFIG_PATH)


func has_configured_key() -> bool:
	return not api_key.strip_edges().is_empty()


func get_effective_base_url() -> String:
	var u := base_url.strip_edges()
	if u.is_empty():
		return "https://api.openai.com/v1"
	return u.rstrip("/")
