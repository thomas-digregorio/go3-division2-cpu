"""Fail-closed registration checks for solver-only AC numerical changes."""
import math

AC_NUMERICS_POLICY = "symbolic_adaptive_v1"
AC_INITIALIZATION_POLICY = "current_schedule_preserving_restarts_v1"


def validate_ac_numerics(config):
    policy = config.get("ac_numerics_policy", "legacy_v1")
    if policy not in ("legacy_v1", AC_NUMERICS_POLICY):
        raise ValueError("Unknown AC numerics policy")
    if policy == AC_NUMERICS_POLICY and (
            config.get("ac_reserve_policy") != "source_joint_reserves_in_ac_v1"
            or config.get("ac_fail_fast_on_infeasible") is not True
            or config.get("ac_correction_policy", "off") != "off"):
        raise ValueError("Symbolic/adaptive AC requires the audited reserve-aware adapter")
    if "ac_first_interval_seconds_per_solve" in config:
        seconds = config["ac_first_interval_seconds_per_solve"]
        if (policy != AC_NUMERICS_POLICY or isinstance(seconds, bool)
                or not isinstance(seconds, (int, float)) or not math.isfinite(seconds)
                or not 0 < seconds <= config.get("total_seconds", 7200)):
            raise ValueError("Invalid first-interval AC allowance")
    if config.get("final_verification_policy", "legacy_v1") not in (
            "legacy_v1", "complete_pipeline_only_v1"):
        raise ValueError("Unknown final verification policy")
    initialization = config.get("ac_initialization_policy", "legacy_v1")
    if initialization not in ("legacy_v1", AC_INITIALIZATION_POLICY):
        raise ValueError("Unknown AC initialization policy")
    if initialization == AC_INITIALIZATION_POLICY and (
            policy != AC_NUMERICS_POLICY
            or config.get("ac_primal_guard") != "verified_stable_rounded_primal_v1"
            or config.get("ac_shunt_primal_start") not in (
                "within_interval_complete_v1", "within_interval_primal_dual_v1")
            or config.get("ac_interval_primal_start") != "previous_screened_interval_v1"):
        raise ValueError("Complete AC initialization requires audited symbolic solves, starts and primal guard")
