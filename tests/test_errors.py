"""Typed error codes become one actionable sentence each."""

from __future__ import annotations

import pytest

from plomada_bridge.errors import NOT_RESPONDING, NotResponding, OutcomeUnknown, SketchUpError, describe

CASES = {
    -32001: ("token", "restart SketchUp"),
    -32002: ("protocol", "same Plomada version"),
    -32003: ("did not finish", "Call it again"),
    -32004: ("refused its input", "Fix that value"),
    -32005: ("SketchUp raised an error", "rolled back"),
    -32006: ("was not queued", "job_status"),
    -32007: ("stopped", "get_plan"),
    -32010: ("execute_ruby is disabled", "Extensions > Plomada > Settings"),
    -32601: ("does not know", "update the Plomada extension"),
}


@pytest.mark.parametrize("code", sorted(CASES))
def test_every_code_is_one_actionable_sentence(code):
    text = describe(SketchUpError(code, "detail here."), "build_plan")
    what, action = CASES[code]
    assert what in text and action in text
    assert "\n" not in text
    assert str(code) in text


def test_reverted_jobs_say_so():
    err = SketchUpError(-32003, "expired: build_plan passed its deadline", {"reverted": True})
    assert "restored to its state before the call" in describe(err, "build_plan")


def test_not_responding_is_exact():
    assert describe(NotResponding(), "status") == NOT_RESPONDING
    assert NOT_RESPONDING == "SketchUp is not responding: a modal dialog may be open in SketchUp, close it and retry"


def test_outcome_unknown_passes_through():
    assert describe(OutcomeUnknown("build_plan: outcome unknown"), "x") == "build_plan: outcome unknown"
