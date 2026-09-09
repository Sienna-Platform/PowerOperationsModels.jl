# Pending work — after the EnergyTargetFeedforward port (2026-09-10)

State at this commit: the SSS `EnergyTargetFeedforward` port is complete on `lk/events-port`
(storage twin of `ReservoirTargetFeedforward`; shared constraint helper; attach-time conflict
guard widened; two count-based and four semantic testsets live). Per-file gates green
(`test_feedforwards` 4379/4379, `test_storage_device_models` 229/229); full suite
129097/129101 under `--jobs=8` with 4 environmental errors (item 3).

## 1. PSY / IS loss-curve catch-up — blocks CI and docs (do first)

- PSY `psy6` tip (PR #1781, merged 2026-09-09 17:06Z) pins IS to `lk/loss-curve-units-v2`, which
  defines `AnyLossCurve`; POM pins IS to `IS4` in `Project.toml`, `test/Project.toml`,
  `docs/Project.toml`. A fresh resolve of PSY therefore fails to precompile — **every POM CI
  run started after that merge fails**, and the docs build fails locally.
- Moving the IS pin forces PSY to the tip, where `PSY.get_loss(d)` returns a `LossCurve{T,U}`
  wrapper. POM's four callers in `src/twoterminal_hvdc_models/TwoTerminalDC_branches.jl`
  (`isa(loss, PSY.LinearCurve)` / `PiecewiseIncrementalCurve` at ~110, 176, 336, 781) would then
  reject every HVDC branch at build.
- Work: re-pin IS in the three `Project.toml` `[sources]` (co-dev pin, temporary until
  `lk/loss-curve-units-v2` merges to IS4); adopt `LossCurve` in `TwoTerminalDC_branches.jl`
  (unwrap via the `ValueCurveWithUnits` accessors, `PSY.SU`, dispatch on the curve type instead
  of `isa`) — this also retires the `get_loss` bare-unit debt listed in `.claude/CLAUDE.md`.
- Do NOT pin PSY to `main`: `main` and `psy6` have diverged (psy6 +296 commits); `main` has
  none of the psy6 API POM uses.

## 2. Uncommitted in the working tree — events gap-review follow-ups (separate effort)

Six files from the events gap review are finished and unstaged, deliberately not in this commit:

- `Project.toml`, `test/Project.toml` — IOM `[sources]` reverted from the temporary
  `jd/share-template-references` pin to `rev = "main"` (IOM #164 is merged). Safe to commit.
- `docs/Project.toml` — `PowerTimeSeriesOpenAPIModels` → `InfrastructureTimeSeriesOpenAPIModels`
  (the subpackage was renamed upstream; this is why the Documentation CI job fails on `main`).
- `src/core/feedforward_interface.jl` — header rewritten (it still said events were not ported).
- `src/event_models/event_model.jl` — `get_empty_timeseries_mapping` fallback: a non-event
  `PSY.Contingency` (e.g. `PlannedOutage`) errors with a typed message instead of `MethodError`.
- `src/event_models/event_runtime.jl` — the `outage_power_offset` TODO moved out of the docstring
  and reworded; PSI #1664 now delegates offsets here, so the remaining gap is validation against
  pre-port PSI results in a full simulation.

## 3. Test-suite flake — pre-existing, not from this work

`--jobs=8` intermittently errors 1–4 testsets with `ArgumentError: invalid JSON at byte position 0
… UnexpectedEOF` in `PSB._build_system`: tests calling `build_system(…; force_build = true)` on a
shared fixture (`c_sys5_uc`, `sys10_pjm_ac_dc`) rewrite PSB's cache while a sibling worker reads
it. 14 such sites (`test_device_load_constructors.jl`, `test_vsc_reactive_models.jl`,
`test_model_decision.jl`, `test_device_hydro_constructors.jl`,
`test_interconnecting_converter_reactive_models.jl`). Victims pass alone. Fix on the test side
(`skip_serialization`, or no `force_build` on shared fixtures) or make PSB's cache write atomic.

## 4. Deferred minors from the port's reviews

- Source meta strings `"$(var_type)target"` (hydro and storage FF constraints) are
  active-module-dependent; prefer `nameof`. Touches hydro; change with the next hydro pass.
- The attach-time guard dispatches on a 4-member inline `Union` of feedforward types
  (`_check_target_feedforward_source_conflict`); a `_checks_source_conflict(::Type)` trait is the
  style-pure form.
- Hydro's coefficient testset (`test_feedforwards.jl` ~1148) still uses `isa` for its set check.
- One-step storage `add_variables!` for `StorageEnergyShortageVariable` has only an
  `IS.FlattenIteratorWrapper` method; a `Vector` of devices would fall through to IOM's generic
  full-horizon, unbounded slack. Unreachable today (constructors pass `get_available_components`).
- `energy_target = true` combined with `EnergyTargetFeedforward` fails with IOM's generic
  "already stored" `InvalidValue`; a purpose-built message was deliberately not added.
- Expected `@error`/`@warn` lines in test output from the collision testset and an existing
  storage testset.
- The `ff_formulations` table and the feedforwards guide document 5 of POM's 9 feedforward types;
  the four hydro/water ones (`ReservoirTargetFeedforward`, `ReservoirLimitFeedforward`,
  `WaterLevelBudgetFeedforward`, `HydroUsageLimitFeedforward`) have no rows or bullets.

## 5. Other open items

- `EnergyLimitFeedforward` (the other SSS feedforward) is not ported; POM's
  `ReservoirLimitFeedforward` is its twin — same shape of work as this port if storage needs it.
  The fenced `EnergyLimitFeedforward … BookKeeping` testset in `test_storage_device_models.jl`
  stays fenced until then.
- PSI (`jd/pom_excision`) pins POM to `lk/events-port`; flip to `main` after PR #286 merges.
- Docs build: verify on CI once item 1 lands (`EnergyTargetFeedforward` is exported with a
  docstring; API pages are `@autodocs`).
- `outage_power_offset` whole-duration semantics vs pre-port PSI's single-step write: validate in
  a full simulation (HPS/SSS-style comparison).
- Next port plan: when a plan says "mirror X", enumerate X's framework touchpoints (grep X's name
  repo-wide) — the attach-time conflict guard was found only by the whole-branch review.
