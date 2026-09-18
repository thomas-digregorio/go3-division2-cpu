"""Ordering for independently verified candidates, without solving any model.

Prepared separately from the frozen r04 controller. Not used by an experiment
until its caller is integrated, component-tested and frozen in a later revision.
Hash/immutable-file checks remain the retaining controller's responsibility.
"""

import math
from numbers import Real


def verified_candidate_rank(certificate, *, prefer_physical=False):
    """Return an ordered tuple, or None when the verification is not usable.

    Historical hard-feasible pilots rank by objective alone. The quality campaign
    additionally requires physically feasible points. Once such a point exists,
    no higher-scoring hard-only point may displace it. Before that, keeping the
    best hard-only point is useful failure evidence, not campaign success.
    """
    if not certificate or not certificate.get("pass") or not certificate.get("complete"):
        return None
    objective = certificate.get("objective")
    if isinstance(objective, bool) or not isinstance(objective, Real) or not math.isfinite(objective):
        return None
    if not prefer_physical:
        return (0, float(objective))
    required = certificate.get("contingencies_required")
    if (certificate.get("official_feas") != 1 or
        certificate.get("independent_hard_pass") is not True or
        certificate.get("objective_agreement") is not True or
        isinstance(required, bool) or not isinstance(required, int) or required <= 0 or
        certificate.get("contingencies_completed") != required):
        return None
    return (int(certificate.get("official_phys_feas") == 1), float(objective))


def prefer_verified_candidate(candidate, current, *, prefer_physical=False):
    """Keep the first candidate on ties and reject incomplete/nonfinite data."""
    rank = verified_candidate_rank(candidate, prefer_physical=prefer_physical)
    current_rank = verified_candidate_rank(current, prefer_physical=prefer_physical)
    return rank is not None and (current_rank is None or rank > current_rank)
