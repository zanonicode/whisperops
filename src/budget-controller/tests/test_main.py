import os
from unittest.mock import MagicMock, patch

import pytest

os.environ.setdefault("LANGFUSE_PUBLIC_KEY", "test-public-key")
os.environ.setdefault("LANGFUSE_SECRET_KEY", "test-secret-key")


def make_fake_agent(agent_name: str, namespace: str, budget_usd: str | None = "10.00") -> dict:
    annotations = {}
    if budget_usd is not None:
        annotations["whisperops.io/budget-usd"] = budget_usd
    return {
        "metadata": {
            "name": agent_name,
            "namespace": namespace,
            "annotations": annotations,
        }
    }


def test_get_budget_usd_parses_correctly():
    from main import get_budget_usd

    agent = make_fake_agent("worker", "agent-test-abc1", "5.00")
    assert get_budget_usd(agent) == pytest.approx(5.0)


def test_get_budget_usd_returns_none_when_missing():
    from main import get_budget_usd

    agent = make_fake_agent("worker", "agent-test-abc1", None)
    assert get_budget_usd(agent) is None


def test_get_budget_usd_returns_none_on_invalid():
    from main import get_budget_usd

    agent = {
        "metadata": {
            "name": "worker",
            "namespace": "agent-test",
            "annotations": {"whisperops.io/budget-usd": "not-a-number"},
        }
    }
    assert get_budget_usd(agent) is None


@patch("main.get_langfuse_spend", return_value=4.5)
@patch("main.emit_warning_event")
def test_run_once_emits_80_percent_event(mock_emit, mock_spend):
    from main import run_once

    fake_agent = make_fake_agent("worker", "agent-test-x1z", "5.00")

    custom_api = MagicMock()
    custom_api.list_cluster_custom_object.return_value = {"items": [fake_agent]}

    apps_api = MagicMock()
    core_api = MagicMock()

    run_once(custom_api, apps_api, core_api)

    mock_emit.assert_called_once()
    call_args = mock_emit.call_args
    assert "80" in call_args[0][3] or "80" in str(call_args)


@patch("main.get_langfuse_spend", return_value=5.5)
@patch("main.scale_deployments_to_zero")
@patch("main.emit_warning_event")
def test_run_once_scales_to_zero_at_100_percent(mock_emit, mock_scale, mock_spend):
    from main import run_once

    fake_agent = make_fake_agent("worker", "agent-test-y2w", "5.00")

    custom_api = MagicMock()
    custom_api.list_cluster_custom_object.return_value = {"items": [fake_agent]}

    apps_api = MagicMock()
    core_api = MagicMock()

    run_once(custom_api, apps_api, core_api)

    mock_scale.assert_called_once_with(apps_api, "agent-test-y2w")
    mock_emit.assert_called_once()


@patch("main.get_langfuse_spend", return_value=2.0)
@patch("main.emit_warning_event")
@patch("main.scale_deployments_to_zero")
def test_run_once_no_action_below_80_percent(mock_scale, mock_emit, mock_spend):
    from main import run_once

    fake_agent = make_fake_agent("worker", "agent-test-z3k", "5.00")

    custom_api = MagicMock()
    custom_api.list_cluster_custom_object.return_value = {"items": [fake_agent]}

    apps_api = MagicMock()
    core_api = MagicMock()

    run_once(custom_api, apps_api, core_api)

    mock_scale.assert_not_called()
    mock_emit.assert_not_called()


@patch("main.get_langfuse_spend", side_effect=Exception("Langfuse unavailable"))
def test_run_once_handles_langfuse_error_gracefully(mock_spend):
    from main import run_once

    fake_agent = make_fake_agent("worker", "agent-test-q9p", "5.00")

    custom_api = MagicMock()
    custom_api.list_cluster_custom_object.return_value = {"items": [fake_agent]}

    apps_api = MagicMock()
    core_api = MagicMock()

    run_once(custom_api, apps_api, core_api)
