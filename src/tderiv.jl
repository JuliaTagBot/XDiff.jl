
# tensor_deriv.jl - tensor derivative utils (using Einstein notation)

const TDIFF_PHS = [:A, :B, :C, :X, :Y, :V, :W, :Z,
                   :i, :j, :k, :l, :m, :n, :p, :q, :r, :s, :t]

const TDIFF_VAR_NAMES = [:V, :W, :X, :Y]


## tensor derivative type

type TensorDeriv <: AbstractDeriv
    dvar::Expr            # variable being differented, e.g. dz[i,j]
    wrt::Expr             # variable w.r.t. which we differentiate, e.g. dx[m,n]
    ex::Any               # derivative expression, e.g. :(y[j, n]) or 1
    guards::Vector{Expr}  # guards for non-zero elements e.g. [:(j == m)]
end

function TensorDeriv(dex::Expr)
    dvar, wrt = dex.args[1].args[2:3]
    ex = without_guards(dex.args[2])
    guards = get_guards(dex.args[2])
    return TensorDeriv(dvar, wrt, ex, guards)
end


function Base.show(io::IO, td::TensorDeriv)
    grds = (length(td.guards) > 0 ?
            (" * " * join(["($g)" for g in td.guards], " * ")) : "")
    print(io, "$(td.dvar)/$(td.wrt) = $(td.ex) $grds")
end

function Base.copy(td::TensorDeriv; dvar=td.dvar, wrt=td.wrt,
              ex=td.ex, guards=td.guards)
    return TensorDeriv(dvar, wrt, ex, guards)
end

expr(td::TensorDeriv) = td.ex
var_indices(td::TensorDeriv) = convert(Vector{Any}, td.dvar.args[2:end])
wrt_indices(td::TensorDeriv) = convert(Vector{Any}, td.wrt.args[2:end])
deriv_indices(td::TensorDeriv) = vcat(var_indices(td), wrt_indices(td))
all_indices(td::TensorDeriv) = union(deriv_indices(td),
                                     flatten(Any, get_indices(expr(td))))

function to_expr(td::TensorDeriv)
    # dvarname, dvaridxs = string(td.dvar.args[1]), td.dvar.args[2:end]
    # wrtname, wrtidxs = string(td.wrt.args[1]), td.wrt.args[2:end]
    # lhs = Expr(:ref, Symbol(dvarname, wrtname), dvaridxs..., wrtidxs...)
    lhs = :($(td.dvar) / $(td.wrt))
    rhs = length(td.guards) > 0 ? Expr(:call, :*, td.ex, td.guards...) : td.ex
    return Expr(:(=), lhs, rhs)
end

function single_var(td::TensorDeriv)
    new_name = Symbol("$(td.dvar.args[1])_$(td.wrt.args[1])")
    new_idxs = vcat(td.dvar.args[2:end], td.wrt.args[2:end])
    return Expr(:ref, new_name, new_idxs...)
end



"""
Given a set of existing indices and current position of iterator,
find the next index not in the set.
"""
function next_index{T}(existing::Set{T}, pos::Int)
    while pos <= length(IDX_NAMES) && in(IDX_NAMES[pos], existing)
        pos += 1
    end
    if pos <= length(IDX_NAMES)
        return IDX_NAMES[pos], pos + 1
    else
        throw(BoundsError("IDX_NAMES"))
    end
end


function next_indices{T}(existing::Set{T}, pos::Int, count::Int)
    new_indices = Array{Symbol}(0)
    for i=1:count
        new_idx, pos = next_index(existing, pos)
        push!(new_indices, new_idx)
    end
    return new_indices
end


"""
Given a set of existing indicies and possible duplicates, find for each duplicate
a replacement - index from IDX_NAMES that is not used yet.
"""
function index_replacements{T}(existing::Set{T}, maybedups::Vector{T})
    repls = Dict{Symbol,Symbol}()
    pos = 1
    for idx in maybedups
        if in(idx, existing) && !in(idx, keys(repls))
            repls[idx], pos = next_index(union(existing, Set(keys(repls))), pos)
        end
    end
    return repls
end


function reindex_with_guards(td::TensorDeriv)
    DI = union(Set{Symbol}(td.dvar.args[2:end]), Set{Symbol}(td.wrt.args[2:end]))
    pairs = Tuple{Symbol,Symbol}[(grd.args[2], grd.args[3]) for grd in td.guards]
    st, new_pairs = reduce_equalities(pairs, DI)
    new_guards = [:($i1 == $i2) for (i1, i2) in new_pairs]
    new_ex = subs(expr(td), st)
    return copy(td; ex=new_ex, guards=new_guards)
end


function with_pseudo_one{T}(ex::Expr, lhs_idxs::Vector{T})
    rhs_idxs = forall_indices(ex)
    sum_idxs = setdiff(rhs_idxs, lhs_idxs)
    if isempty(sum_idxs)
        return ex
    else
        pseudo_one = Expr(:ref, :I, sum_idxs...)
        return Expr(:call, :*, ex, pseudo_one)
    end
end

with_pseudo_one(x, lhs_idxs) = x

"""
Reindex second tensor derivative so that:

    * td2's var indices match td1's w.r.t. indices
    * no other indices in td2 equal any indices in td1
"""
function reindex_to_match(td1::TensorDeriv, td2::TensorDeriv)
    common_idxs_st = Dict(zip(var_indices(td2), wrt_indices(td1)))
    other_idxs_st = index_replacements(Set(all_indices(td1)), all_indices(td2))
    st = merge(other_idxs_st, common_idxs_st)
    td2_dvar = subs(td2.dvar, st)
    td2_wrt = subs(td2.wrt, st)
    td2_ex = subs(td2.ex, st)
    td2_guards = Expr[subs(g, st) for g in td2.guards]
    td2 = TensorDeriv(td2_dvar, td2_wrt, td2_ex, td2_guards)
    return td1, td2
end


"""
Elementwise multuplication of tensor derivatives.
Example:

    dzdx = dzdy ⊗ dydx

which may expand to:     

    dz[]/dy[i] = v[i]
    dy[i]/dx[j] = w[i,j]
    dz[]/dx[j] = v[i] .* w[i,j]
"""
function ⊗(td1::TensorDeriv, td2::TensorDeriv)
    # can only multiply related derivatives, e.g. dz/dy * dy/dx
    @assert td1.wrt.args[1] == td2.dvar.args[1]
    td1, td2 = reindex_to_match(td1, td2)
    # add pseudo one to enable accurate parsing later
    new_ex1 = with_pseudo_one(expr(td1), deriv_indices(td1))
    new_ex2 = with_pseudo_one(expr(td2), deriv_indices(td2))
    new_ex = simplify(new_ex1 ⊗ new_ex2)
    new_guards = vcat(td1.guards, td2.guards)
    new_td = TensorDeriv(td1.dvar, td2.wrt, new_ex, new_guards)
    return reindex_with_guards(new_td)
end

function tderiv_var(td::TensorDeriv)
    name = Symbol(string(td.dvar.args[1]) * "_" * string(td.wrt.args[1]))
    idxs = vcat(td.dvar.args[2:end], td.wrt.args[2:end])
    return make_indexed(name, idxs)
end


"""Find indices on RHS of TensorDeriv which aren't present on LHS"""
function free_indices(td::TensorDeriv)
    lhs_idxs = vcat(td.dvar.args[2:end], td.wrt.args[2:end])
    rhs_idxs = flatten(get_indices(expr(td)))
    return setdiff(rhs_idxs, lhs_idxs)
end

function ⊕(td1::TensorDeriv, td2::TensorDeriv)
    @assert td1.dvar.args[1] == td2.dvar.args[1]
    @assert td1.wrt.args[1] == td2.wrt.args[1]
    dvar_idxs_st = Dict(zip(var_indices(td2), var_indices(td1)))
    wrt_idxs_st = Dict(zip(wrt_indices(td2), wrt_indices(td1)))
    st = merge(dvar_idxs_st, wrt_idxs_st)
    free_idxs = free_indices(td2)
    # TODO: should we also inclue all indicies of expr(td1)?
    all_existing_idxs = Set{Symbol}(vcat(keys(st)..., values(st)..., free_idxs))
    next_idx_pos = 1
    for idx in free_idxs
        if in(idx, values(st))
            st[idx], next_idx_pos = next_index(all_existing_idxs, next_idx_pos)
        end
    end
    wrt2_reindexed = subs(td2.wrt, st)
    ex2_reindexed = subs(expr(td2), st)
    guards2_reindexed = Expr[subs(g, st) for g in td2.guards]
    new_ex = simplify(expr(td1) ⊕ ex2_reindexed)
    new_guards = vcat(td1.guards, guards2_reindexed)
    new_td = TensorDeriv(td1.dvar, wrt2_reindexed, new_ex, new_guards)
    return reindex_with_guards(new_td)
end




## tensor differentiation rules

immutable TensorDiffRule <: AbstractDiffRule
    pat::Expr             # pattern of expression to differentiate
    deriv::TensorDeriv    # pattern of differentiation expression
end

function Base.show(io::IO, rule::TensorDiffRule)
    print(io, "TensorDiffRule($(rule.pat) ==> $(rule.deriv))")
end


# create elementwise tensor diff rule from ordinary diff rule
function ew_to_tensor_rule(ew_rule::DiffRule, diff_idx::Int, num_idxs::Int)
    ew_pat = ew_rule.pat
    op = ew_pat.args[1]
    ew_ex = ew_rule.deriv.ex
    # tensor var names and indices
    tvar_names = TDIFF_VAR_NAMES[1:length(ew_pat.args)-1]
    tvar_idxs = IDX_NAMES[1:num_idxs]
    tvars = [Expr(:ref, tvar, tvar_idxs...) for tvar in tvar_names]
    # dvar variable
    odvar_name = :Z
    dvar_name = dname(odvar_name)
    dvar_idxs = tvar_idxs
    dvar = Expr(:ref, dvar_name, dvar_idxs...)
    odvar = Expr(:ref, odvar_name, dvar_idxs...)
    # w.r.t. variable
    owrt_name = tvar_names[diff_idx]
    wrt_name = dname(owrt_name)
    wrt_idxs = IDX_NAMES[num_idxs+1:2*num_idxs]
    wrt = Expr(:ref, wrt_name, wrt_idxs...)
    # new pattern
    tpat = Expr(:call, op, tvars...)
    full_tpat = :($odvar = $tpat)
    # elementwise derivative expression
    tex = rewrite(tpat, ew_pat, ew_ex; phs=DIFF_PHS)
    # tex_lhs = :($dvar / $wrt)
    # full_tex = :($tex_lhs = $tex)
    # constructing tensor derivative
    tguards = [:($i1 == $i2) for (i1, i2) in zip(dvar_idxs, wrt_idxs)]
    tderiv = TensorDeriv(dvar, wrt, tex, tguards)
    return TensorDiffRule(full_tpat, tderiv)
end


"""
Ensures that its argument is an indexed expression:

    ensure_indexed(:x, [])          ==> :(x[])
    ensure_indexed(:X, [:i])        ==> :(x[i])
    ensure_indexed(:(x[k]), [:i])   ==> :(x[k])
"""
function ensure_indexed(ex::Expr, idxs::Vector)
    @assert (ex.head == :ref) "Argument is not a symbol and not indexed already"
    return ex
end

function ensure_indexed(var::Symbol, idxs::Vector)
    return Expr(:ref, var, idxs...)
end


"""
Convert scalar diff rule to a tensor diff rule.

 * ew_rule   - elementwise (scalar) rule
 * orig_idxs - indices of full tensor expression,
               e.g. for `z[i] = X[i,j] * y[j]` it's [[:i], [:i, :j], [:j]]
 * idx       - index of input parameter to differentiate w.r.t. it
"""
function to_tensor_rule{T}(ew_rule::DiffRule, orig_idxs::Vector{Vector{T}}, idx::Int)
    ew_pat = ew_rule.pat
    op = ew_pat.args[1]
    ew_ex = ew_rule.deriv.ex
    # tensor var names and indices
    tvar_names = TDIFF_VAR_NAMES[1:length(ew_pat.args)-1]
    # tvar_idxs = IDX_NAMES[1:length(orig_idxs[1])]
    tvars = [make_indexed(name, IX) for (name, IX) in zip(tvar_names, orig_idxs[2:end])]
    tvar_idxs = IDX_NAMES[1:length(orig_idxs[1])]
    # tvars = [Expr(:ref, tvar, tvar_idxs...) for tvar in tvar_names]
    # dvar variable
    var_name = :Z
    dvar_name = dname(var_name)
    var = make_indexed(var_name, orig_idxs[1])
    dvar = make_indexed(dvar_name, orig_idxs[1])
    # w.r.t. variable
    wrt_name = tvar_names[idx]
    dwrt_name = dname(wrt_name)
    wrt_idxs = next_indices(Set(flatten(Symbol, orig_idxs)), 1, length(orig_idxs[idx + 1]))
    dwrt = make_indexed(dwrt_name, wrt_idxs)
    # new pattern
    tpat = Expr(:call, op, tvars...)
    full_tpat = :($var = $tpat)
    # new tensor derivative expression
    tex = rewrite(tpat, ew_pat, ew_ex; phs=DIFF_PHS)
    # constructing tensor derivative
    if length(orig_idxs[idx + 1]) > 0
        # old and new w.r.t. indices must be equal
        tguards = Expr[:($i1 == $i2) for (i1, i2) in zip(orig_idxs[idx+1], wrt_idxs)]
    else
        tguards = Expr[]  # TODO: this should be covered by previous definition too
    end
    # REFAC: indexed => make_indexed
    tderiv = TensorDeriv(ensure_indexed(dvar, orig_idxs[1]),
                         ensure_indexed(dwrt, wrt_idxs), tex, tguards)
    return TensorDiffRule(full_tpat, tderiv)
end



const TENSOR_DIFF_RULES = Dict{Tuple{OpName, Int}, Vector{TensorDiffRule}}()


function push_tdiff_rule!(op::OpName, deriv_idx::Int, rule::TensorDiffRule)
    if !haskey(TENSOR_DIFF_RULES, (op, deriv_idx))
        TENSOR_DIFF_RULES[(op, deriv_idx)] = TensorDiffRule[]
    end
    push!(TENSOR_DIFF_RULES[(op, deriv_idx)], rule)
end

function _tdiff_rule(ex, dex)
    op = canonical(current_module(), ex.args[2].args[1])
    idxs = get_indices(ex.args[2])
    dvar = dex.args[1].args[2]
    wrt = dex.args[1].args[3]
    deriv_ex = without_guards(sanitize(dex.args[2]))
    guards = get_guards(dex)
    deriv = TensorDeriv(dvar, wrt, deriv_ex, guards)
    diff_var_name = Symbol(string(wrt.args[1])[2:end])
    var_names = [iex.args[1] for iex in ex.args[2].args[2:end]]
    deriv_idx = find(var_names .== diff_var_name)[1]
    rule = TensorDiffRule(ex, deriv)
    push_tdiff_rule!(op, deriv_idx, rule)
end


macro tdiff_rule(ex, dex)
    _tdiff_rule(ex, dex)
    nothing
end


function tfind_rule(fullex::Expr, idx::Int)
    @assert fullex.head == :(=) && fullex.args[2].head == :call
    op = fullex.args[2].args[1]  # TODO: opname(current_module(), op)?
    haskey(TENSOR_DIFF_RULES, (op, idx)) || return Nullable{TensorDiffRule}()
    rules = TENSOR_DIFF_RULES[(op, idx)]
    matches = pat -> !isnull(matchex(pat, fullex; phs=TDIFF_PHS, allow_ex=false))
    matching = findfirst(matches,
                         [r.pat for r in rules])
    matching != 0 || return Nullable{TensorDiffRule}()
    return Nullable{TensorDiffRule}(rules[matching])

    # TODO: TensorDiffRule(ew_diff_rule) should take into account qualified names

end

dname(var::Symbol) = Symbol("d$var")
undname(dvar::Symbol) = Symbol(string(dvar)[2:end])


"""dZ[i]/dX[j] = ... ==> Z[i]/X[i] = ..."""
function unpack_deriv(ex::Expr)
    @assert ex.head == :(=)
    @assert ex.args[1].head == :call && ex.args[1].args[1] == :/
    dvar, dwrt = [dv.args[1] for dv in ex.args[1].args[2:3]]
    var, wrt = undname(dvar), undname(dwrt)
    return subs(ex, Dict(dvar => var, dwrt => wrt))
end

"""Z[i]/X[j] = ... ==> dZ[i]/dX[i] = ..."""
function pack_deriv(ex::Expr)
    @assert ex.head == :(=)
    @assert ex.args[1].head == :call && ex.args[1].args[1] == :/
    var, wrt = [v.args[1] for v in ex.args[1].args[2:3]]
    dvar, dwrt = dname(var), dname(wrt)
    lhs = subs(ex.args[1], Dict(var => dvar, wrt => dwrt))
    rhs = ex.args[2]
    return Expr(:(=), lhs, rhs)
end


function tderivative(fullex::Expr, idx::Int)
    maybe_rule = tfind_rule(fullex, idx)
    if !isnull(maybe_rule)
        rule = get(maybe_rule)
        unpacked_rule_dex = unpack_deriv(to_expr(rule.deriv))
        unpacked_dex = rewrite(fullex, rule.pat, unpacked_rule_dex; phs=TDIFF_PHS)
        dex = pack_deriv(unpacked_dex)
        return TensorDeriv(dex)
    else
        idxs = get_indices(fullex)
        # elementwise or broadcasting function
        op = opname(current_module(), fullex.args[2].args[1])
        types = [Float64 for i=1:length(fullex.args[2].args)-1]
        ew_maybe_rule = find_rule(op, types, idx)
        ew_rule = (!isnull(ew_maybe_rule) ? get(ew_maybe_rule) :
                   register_rule(op, types, idx))
        trule = to_tensor_rule(ew_rule, idxs, idx)
        push_tdiff_rule!(op, idx, trule)
        # now rule is registered, recursively call itself
        return tderivative(fullex, idx)
    end
end

function tderivative(fullex::Expr, var::Symbol)
    @assert fullex.head == :(=)
    @assert fullex.args[2].head == :call
    ivars = [var for var in fullex.args[2].args[2:end]]
    vars = [isa(ivar, Expr) ? ivar.args[1] : ivar for ivar in ivars]
    matching = findfirst(vars .== var)
    matching != 0 || error("Variable `$dvar` isn't present " *
                           "in expression `$fullex`")
    return tderivative(fullex, matching[1])
end
