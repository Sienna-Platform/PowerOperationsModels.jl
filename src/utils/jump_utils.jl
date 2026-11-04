"""
Drop the terms of `expr` with a coefficient within `EXPRESSION_ROUNDING_TOL` of zero. Set the
coefficients within that tolerance of 1 or -1 to exactly 1 or -1. Leave the other
coefficients and the constant unchanged. Call it once, after all additions into `expr` are
complete.
"""
function round_to_zero_or_one!(expr::JuMP.GenericAffExpr{C}) where {C}
    atol = C(EXPRESSION_ROUNDING_TOL)
    terms = expr.terms
    for (x, c) in terms
        if abs(c - one(C)) <= atol
            terms[x] = one(C)
        elseif abs(c + one(C)) <= atol
            terms[x] = -one(C)
        end
    end
    filter!(p -> abs(p.second) > atol, terms)
    return expr
end
