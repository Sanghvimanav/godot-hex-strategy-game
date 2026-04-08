class_name LlmOpenAiClient
extends RefCounted
## OpenAI-compatible POST {base}/chat/completions. Uses one HTTPRequest node in the tree; supports cancel (spec Phase 1).
## Spec §2.3 uses 15s connect + 60s read; Godot 4 HTTPRequest exposes a single timeout (seconds) for the whole request, so we set that to 60 (planning) / 45 (post-game).

enum Profile {
	PLANNING,
	POST_GAME,
}


static func timeout_seconds(profile: Profile) -> float:
	match profile:
		Profile.POST_GAME:
			return 45.0
		_:
			return 60.0


static func default_max_tokens(profile: Profile) -> int:
	match profile:
		Profile.POST_GAME:
			return 1024
		_:
			return 2048


## Newer OpenAI models reject max_tokens (400) and require max_completion_tokens instead.
static func _use_max_completion_tokens(model_id: String) -> bool:
	var m := model_id.strip_edges().to_lower()
	if m.is_empty():
		return false
	if m.begins_with("o1") or m.begins_with("o3") or m.begins_with("o4"):
		return true
	if m.begins_with("gpt-5"):
		return true
	return false


var _cancel_generation: int = 0


func cancel_inflight(http: HTTPRequest) -> void:
	if http == null:
		return
	_cancel_generation += 1
	http.cancel_request()


func get_cancel_generation() -> int:
	return _cancel_generation


## Returns { "ok": true, "content": String } or { "ok": false, "error": String, "result_code"?: int, "http_status"?: int }.
func chat_completions(
	http: HTTPRequest,
	base_url: String,
	api_key: String,
	model: String,
	messages: Array,
	profile: Profile = Profile.PLANNING,
	max_tokens: int = -1,
) -> Dictionary:
	if http == null:
		return { "ok": false, "error": "http_missing" }
	var trimmed_key := api_key.strip_edges()
	if trimmed_key.is_empty():
		return { "ok": false, "error": "missing_api_key" }
	var trimmed_model := model.strip_edges()
	if trimmed_model.is_empty():
		return { "ok": false, "error": "missing_model" }

	var gen_at_start: int = _cancel_generation
	http.timeout = timeout_seconds(profile)

	var url := "%s/chat/completions" % base_url.rstrip("/")
	var cap: int = max_tokens
	if cap < 0:
		cap = default_max_tokens(profile)
	if cap > 0:
		cap = clampi(cap, 1, 128000)
	var body_dict: Dictionary = {
		"model": trimmed_model,
		"messages": messages,
	}
	if cap > 0:
		if _use_max_completion_tokens(trimmed_model):
			body_dict["max_completion_tokens"] = cap
		else:
			body_dict["max_tokens"] = cap
	var json_body := JSON.stringify(body_dict)
	if json_body.is_empty():
		return { "ok": false, "error": "json_encode_failed" }

	var headers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer %s" % trimmed_key,
		"Content-Type: application/json",
	])
	var err: Error = http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		return { "ok": false, "error": "request_start_failed", "result_code": err }

	var response: Variant = await http.request_completed
	if gen_at_start != _cancel_generation:
		return { "ok": false, "error": "cancelled" }

	var res: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if res != HTTPRequest.RESULT_SUCCESS:
		return { "ok": false, "error": _result_code_to_reason(res), "result_code": res }

	if response_code < 200 or response_code >= 300:
		var snippet := _body_snippet(body)
		return { "ok": false, "error": "http_%d" % response_code, "http_status": response_code, "body_snippet": snippet }

	var parse_any: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parse_any) != TYPE_DICTIONARY:
		return { "ok": false, "error": "invalid_response_json" }
	var root: Dictionary = parse_any
	var choices: Array = root.get("choices", []) as Array
	if choices.is_empty():
		return { "ok": false, "error": "no_choices" }
	var first: Variant = choices[0]
	if typeof(first) != TYPE_DICTIONARY:
		return { "ok": false, "error": "bad_choice_shape" }
	var msg: Dictionary = (first as Dictionary).get("message", {}) as Dictionary
	var content: String = str(msg.get("content", ""))
	return { "ok": true, "content": content }


## OpenAI Responses API: thinking / GPT-5 family. POST {base}/responses with reasoning.effort and max_output_tokens.
## instructions ~= system prompt; user_content ~= user JSON snapshot.
func responses_create(
	http: HTTPRequest,
	base_url: String,
	api_key: String,
	model: String,
	instructions: String,
	user_content: String,
	reasoning_effort: String,
	max_output_tokens: int,
) -> Dictionary:
	if http == null:
		return { "ok": false, "error": "http_missing" }
	var trimmed_key := api_key.strip_edges()
	if trimmed_key.is_empty():
		return { "ok": false, "error": "missing_api_key" }
	var trimmed_model := model.strip_edges()
	if trimmed_model.is_empty():
		return { "ok": false, "error": "missing_model" }

	var gen_at_start: int = _cancel_generation
	http.timeout = 120.0

	var url := "%s/responses" % base_url.rstrip("/")
	var cap: int = max_output_tokens
	if cap < 0:
		cap = default_max_tokens(Profile.PLANNING)
	if cap > 0:
		cap = clampi(cap, 1, 65536)

	var effort := reasoning_effort.strip_edges().to_lower()
	if effort.is_empty():
		effort = "medium"

	var body_dict: Dictionary = {
		"model": trimmed_model,
		"instructions": instructions,
		"input": [{"role": "user", "content": user_content}],
		"reasoning": {"effort": effort},
	}
	if cap > 0:
		body_dict["max_output_tokens"] = cap

	var json_body := JSON.stringify(body_dict)
	if json_body.is_empty():
		return { "ok": false, "error": "json_encode_failed" }

	var headers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer %s" % trimmed_key,
		"Content-Type: application/json",
	])
	var err: Error = http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		return { "ok": false, "error": "request_start_failed", "result_code": err }

	var response: Variant = await http.request_completed
	if gen_at_start != _cancel_generation:
		return { "ok": false, "error": "cancelled" }

	var res: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if res != HTTPRequest.RESULT_SUCCESS:
		return { "ok": false, "error": _result_code_to_reason(res), "result_code": res }

	if response_code < 200 or response_code >= 300:
		var snippet := _body_snippet(body, 500)
		return { "ok": false, "error": "http_%d" % response_code, "http_status": response_code, "body_snippet": snippet }

	var parse_any: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parse_any) != TYPE_DICTIONARY:
		return { "ok": false, "error": "invalid_response_json" }
	var root: Dictionary = parse_any
	var status: String = str(root.get("status", "completed"))
	if status == "failed":
		var err_obj: Variant = root.get("error", null)
		return { "ok": false, "error": "response_failed", "detail": str(err_obj) }

	var text_out := _extract_responses_output_text(root)
	if text_out.is_empty() and status == "incomplete":
		var inc: Variant = root.get("incomplete_details", null)
		return { "ok": false, "error": "incomplete_response", "detail": str(inc) }
	if text_out.is_empty():
		return { "ok": false, "error": "no_output_text" }

	return { "ok": true, "content": text_out }


static func _extract_responses_output_text(root: Dictionary) -> String:
	var out: Array = root.get("output", []) as Array
	for item in out:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		if str(d.get("type", "")) != "message":
			continue
		var content: Array = d.get("content", []) as Array
		for part in content:
			if typeof(part) != TYPE_DICTIONARY:
				continue
			var p: Dictionary = part
			if str(p.get("type", "")) == "output_text":
				return str(p.get("text", ""))
	return ""


static func _result_code_to_reason(res: int) -> String:
	match res:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "cant_connect"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "cant_resolve"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection_error"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "no_response"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "request_failed"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "body_too_large"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH:
			return "chunked_body_error"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED:
			return "decompress_failed"
		_:
			return "request_error_%d" % res


static func _body_snippet(body: PackedByteArray, max_len: int = 200) -> String:
	if body.is_empty():
		return ""
	var s := body.get_string_from_utf8()
	if s.length() > max_len:
		return s.substr(0, max_len) + "…"
	return s
