"""Pydantic validation: errors start with the field path, in the extension's wording."""

from __future__ import annotations

import copy

import pytest

from conftest import DXF
from plomada_bridge.dxf import read_plan
from plomada_bridge.models import parse_plan


@pytest.fixture(scope="module")
def raw():
    plan = read_plan(DXF).plan.to_wire()
    plan.pop("storey", None)
    return plan


def refuse(raw, mutate):
    data = copy.deepcopy(raw)
    mutate(data)
    with pytest.raises(ValueError) as info:
        parse_plan(data)
    return str(info.value)


def test_negative_thickness(raw):
    assert refuse(raw, lambda d: d["walls"][2].update(thickness=-200)) == (
        "walls[2].thickness must be greater than 0, got -200"
    )


def test_bad_choice_and_missing_field(raw):
    assert refuse(raw, lambda d: d["walls"][0].update(justification="middle")) == (
        "walls[0].justification must be one of 'center', 'left' or 'right', got 'middle'"
    )
    assert refuse(raw, lambda d: d["openings"][1].pop("width")) == "openings[1].width is required"


def test_version_and_references(raw):
    assert refuse(raw, lambda d: d["rooms"][0].update(v=2)) == ("rooms[0].v is 2; Plomada reads record version 1 only")
    msg = refuse(raw, lambda d: d["openings"][3].update(wall="NOPE"))
    assert msg.startswith("openings[3].wall names 'NOPE', which is not in the plan")
    assert refuse(raw, lambda d: d["walls"][1].update(id=d["walls"][0]["id"])) == (
        "walls[1].id repeats 'P1' from walls[0]"
    )


def test_axis_shape(raw):
    assert refuse(raw, lambda d: d["walls"][0].update(axis=[[0, 0]])) == (
        "walls[0].axis must hold at least 2 items, got 1"
    )
    assert refuse(raw, lambda d: d["walls"][2].update(axis=[[0, 0], [1, 1]], closed=True)) == (
        "walls[2].axis must hold at least 3 points for a closed wall, got 2"
    )
    assert refuse(raw, lambda d: d["walls"][0].update(axis=[[0, 0], [0, 0]])) == (
        "walls[0].axis[1] repeats axis[0]; a zero-length segment has no direction"
    )
    assert refuse(raw, lambda d: d["walls"][0]["axis"][1].__setitem__(1, "x")) == (
        "walls[0].axis[1][1] must be a number, got 'x'"
    )


def test_negative_offset_and_sill(raw):
    assert refuse(raw, lambda d: d["openings"][0].update(offset=-5)) == (
        "openings[0].offset must be greater than or equal to 0, got -5"
    )


def test_valid_plan_round_trips(raw):
    plan = parse_plan(copy.deepcopy(raw))
    assert plan.to_wire()["walls"] == raw["walls"]
