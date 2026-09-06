from pathlib import Path


def test_training_does_not_reimplement_handwritten_evaluator() -> None:
    train_source = Path("ml/value_model/train.py").read_text()
    metrics_source = Path("ml/value_model/metrics.py").read_text()

    assert "handwritten_evaluator_score(" not in train_source
    assert "handwritten_evaluator_score" not in metrics_source
    assert "TERMINAL_WEIGHT" not in metrics_source
    assert "UNIT_COUNT_WEIGHT" not in metrics_source
    assert "HEALTH_WEIGHT" not in metrics_source
    assert "RESOURCE_WEIGHT" not in metrics_source


def test_handwritten_comparison_requires_real_evaluator_fingerprint() -> None:
    train_source = Path("ml/value_model/train.py").read_text()

    assert "evaluator_fingerprint" in train_source
    assert "not_reported_without_godot_baseline" in train_source
