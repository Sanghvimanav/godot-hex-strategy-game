from pathlib import Path


def test_training_does_not_reimplement_handwritten_evaluator() -> None:
    train_source = Path("ml/value_model/train.py").read_text()
    metrics_source = Path("ml/value_model/metrics.py").read_text()

    assert "handwritten_evaluator_score(" not in train_source
    assert "PureStateEvaluator" not in metrics_source
    assert "handwritten_evaluator_score" not in metrics_source
