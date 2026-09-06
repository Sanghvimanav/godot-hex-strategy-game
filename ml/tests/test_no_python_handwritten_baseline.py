from pathlib import Path


def test_training_never_uses_python_handwritten_clone() -> None:
    train_source = Path("ml/value_model/train.py").read_text()

    assert "handwritten_evaluator_score(" not in train_source
    assert "not_reported_without_godot_baseline" in train_source
    assert "evaluator_fingerprint" in train_source


def test_handwritten_metric_requires_godot_annotation_for_real_states() -> None:
    metrics_source = Path("ml/value_model/metrics.py").read_text()

    assert "_godot_handwritten_evaluator_score" in metrics_source
    assert "missing _godot_handwritten_evaluator_score" in metrics_source
    assert 'scenario_id", "")) != "synthetic"' in metrics_source
