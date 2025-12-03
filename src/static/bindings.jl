#=
Binding information for `EXPR`.

NOTE:
- Since we only want really basic information about `EXPR`, let's just add binding information
    for `EXPR.meta` field for now.
- Adapted from https://github.com/julia-vscode/StaticLint.jl/blob/619d2d7138e921e5748db32002051666ef2d54f0/src/bindings.jl
=#

struct Binding
    name::String
    val::Union{Binding,EXPR,Nothing}
    # NOTE: omitted: type, refs, prev, next
end
function Binding(expr::EXPR, val::Union{Binding,EXPR,Nothing})
    ex = CSTParser.get_name(expr)
    name = if (name = valof(ex)) === nothing
        headof(ex) === :OPERATOR ? str_value(ex) : ""
    else
        name
    end
    return Binding(name, val)
end
Binding(expr::EXPR) = Binding(expr, expr)

Base.show(io::IO, bind::Binding) = printstyled(io, ' ', "Binding(", bind.name, ')'; color = :blue)

hasbinding(expr::EXPR) = expr.meta isa Binding
bindingof(expr::EXPR)::Union{Nothing,Binding} = hasbinding(expr) ? expr.meta : nothing

# adapted from https://github.com/julia-vscode/StaticLint.jl/blob/3a24e4b84a419ea607aaa51e42b3b45d172438c8/src/StaticLint.jl#L78-L113
"""
    traverse_expr!(x::EXPR)

Iterates across the child nodes of an `EXPR` in execution order calling
  [`mark_bindings`](@ref) on each node.
"""
function traverse_expr!(x::EXPR)
    mark_bindings!(x)

    if (CSTParser.isbinarycall(x) || CSTParser.isbinarysyntax(x)) &&
       (
        CSTParser.isassignment(x) && !CSTParser.is_func_call(x.args[1]) ||
        CSTParser.isdeclaration(x)
       ) &&
       !(CSTParser.isassignment(x) && headof(x.args[1]) === :curly)
        if CSTParser.isbinarycall(x)
            traverse_expr!(x.args[3])
            traverse_expr!(x.args[2])
            traverse_expr!(x.args[1])
        else
            traverse_expr!(x.args[2])
            traverse_expr!(x.args[1])
        end
    elseif headof(x) === :where
        @inbounds for i = 3:length(x.args)
            traverse_expr!(x.args[i])
        end
        traverse_expr!(x.args[1])
        traverse_expr!(x.args[2])
    elseif headof(x) === :generator
        @inbounds for i = 2:length(x.args)
            traverse_expr!(x.args[i])
        end
        traverse_expr!(x.args[1])
    elseif headof(x) === :flatten &&
           x.args !== nothing && length(x.args) === 1 &&
           x.args[1].args !== nothing &&
           length(x.args[1]) >= 3 && length(x.args[1].args[1]) >= 3
        for i = 3:length(x.args[1].args[1].args)
            traverse_expr!(x.args[1].args[1].args[i])
        end
        for i = 3:length(x.args[1].args)
            traverse_expr!(x.args[1].args[i])
        end
        traverse_expr!(x.args[1].args[1].args[1])
    elseif x.args !== nothing
        @inbounds for i = 1:length(x.args)
            traverse_expr!(x.args[i])
        end
    end
end

function mark_bindings!(x::EXPR)
    hasbinding(x) && return

    if CSTParser.isbinarycall(x) || CSTParser.isbinarysyntax(x)
        op_val = CSTParser.isbinarycall(x) ? CSTParser.valof(x.args[1]) : CSTParser.valof(x.head)
        if op_val == "="
            if CSTParser.is_func_call(x.args[1])
                mark_binding!(x)
                mark_sig_args!(x.args[1])
            elseif headof(x.args[1]) === :curly
                mark_typealias_bindings!(x)
            else
                mark_binding!(x.args[1], x)
            end
        elseif op_val == "->"
            mark_binding!(x.args[1], x)
        end
    elseif headof(x) === :where
        for i = 3:length(x.args)
            headof(x.args[i]) === CSTParser.PUNCTUATION && continue
            mark_binding!(x.args[i])
        end
    elseif headof(x) === :for
        markiterbinding!(x.args[2])
    elseif headof(x) === :generator
        for i = 3:length(x.args)
            headof(x.args[i]) === CSTParser.PUNCTUATION && continue
            markiterbinding!(x.args[i])
        end
    elseif headof(x) === :filter
        for i = 1:length(x.args)-2
            headof(x.args[i]) === CSTParser.PUNCTUATION && continue
            markiterbinding!(x.args[i])
        end
    elseif headof(x) === :do
        if headof(x.args[3]) === :tuple
            for i = 1:length(x.args[3].args)
                headof(x.args[3].args[i]) === :punctuation && continue
                mark_binding!(x.args[3].args[i])
            end
        end
        # markiterbinding!(x.args[3])
    elseif headof(x) === :function
        name = CSTParser.get_name(x)
        # mark external binding
        x.meta = Binding(name, x)
        mark_sig_args!(CSTParser.get_sig(x))
    elseif headof(x) === :module || headof(x) === :baremodule
        x.meta = Binding(x.args[2], x)
    elseif headof(x) === :macro
        name = CSTParser.get_name(x)
        x.meta = Binding(name, x)
        mark_sig_args!(CSTParser.get_sig(x))
    elseif headof(x) === :try && length(x.args) > 3
        mark_binding!(x.args[4])
    elseif headof(x) === :abstract || headof(x) === :primitive
        name = CSTParser.get_name(x)
        x.meta = Binding(name, x)
        mark_parameters(CSTParser.get_sig(x))
    elseif headof(x) === :mutable || headof(x) === :struct
        name = CSTParser.get_name(x)
        x.meta = Binding(name, x)
        mark_parameters(CSTParser.get_sig(x))
        blocki = headof(x.args[3]) === :block ? 3 : 4
        for i = 1:length(x.args[blocki])
            CSTParser.defines_function(x.args[blocki].args[i]) && continue
            mark_binding!(x.args[blocki].args[i])
        end
    elseif headof(x) === :local
        if length(x.args) == 2
            if headof(x.args[2]) === :IDENTIFIER
                mark_binding!(x.args[2])
            elseif headof(x.args[2]) === :tuple
                for i = 1:length(x.args[2].args)
                    if headof(x.args[2].args[i]) === :IDENTIFIER
                        mark_binding!(x.args[2].args[i])
                    end
                end
            end
        end
    end
end

function mark_binding!(x::EXPR, val = x)
    if headof(x) === :kw
        mark_binding!(x.args[1], x)
    elseif headof(x) === :tuple || headof(x) === :parameters
        for arg in x.args
            headof(arg) === :punctuation && continue
            mark_binding!(arg, val)
        end
    elseif (CSTParser.isbinarycall(x) || CSTParser.isbinarysyntax(x)) &&
           (op_val = CSTParser.isbinarycall(x) ? CSTParser.valof(x.args[1]) : CSTParser.valof(x.head);
            op_val == "::") &&
           headof(x.args[1]) === :tuple
        mark_binding!(x.args[1], x)
    elseif headof(x) === :brackets
        mark_binding!(CSTParser.rem_invis(x), val)
    elseif (CSTParser.isunarycall(x) || CSTParser.isunarysyntax(x)) &&
           CSTParser.valof(CSTParser.isunarycall(x) ? x.args[1] : x.head) == "::"
        return x
    elseif headof(x) === :ref
        # https://github.com/JunoLab/Juno.jl/issues/502
        return x
    else# if headof(x) === :IDENTIFIER || (isbinarysyntax(x) && valof(x.head) == "::")
        x.meta = Binding(CSTParser.get_name(x), val)
    end
    return x
end

function mark_parameters(sig::EXPR)
    signame = CSTParser.rem_where_subtype(sig)
    if headof(signame) === :curly
        for i = 3:length(signame.args)-1
            if headof(signame.args[i]) !== :punctuation
                mark_binding!(signame.args[i])
            end
        end
    end
    return sig
end

function markiterbinding!(iter::EXPR)
    if (CSTParser.isbinarycall(iter) || CSTParser.isbinarysyntax(iter)) &&
       (op_val = CSTParser.isbinarycall(iter) ? CSTParser.valof(iter.args[1]) : CSTParser.valof(iter.head);
        op_val in ("=", "in", "∈"))
        var_index = CSTParser.isbinarycall(iter) ? 2 : 1
        mark_binding!(iter.args[var_index], iter)
    elseif headof(iter) === :block
        for i = 1:length(iter.args)
            headof(iter.args[i]) === :punctuation && continue
            markiterbinding!(iter.args[i])
        end
    end
    return iter
end

function mark_sig_args!(x::EXPR)
    if headof(x) === :call || headof(x) === :tuple
        if headof(x.args[1]) === :brackets &&
           (CSTParser.isbinarycall(x.args[1].args[2]) || CSTParser.isbinarysyntax(x.args[1].args[2])) &&
           CSTParser.valof(CSTParser.isbinarycall(x.args[1].args[2]) ? x.args[1].args[2].args[1] : x.args[1].args[2].head) == "::"
            mark_binding!(x.args[1].args[2])
        end
        for i = 2:length(x.args)-1
            a = x.args[i]
            if headof(a) === :parameters
                for j = 1:length(a.args)
                    aa = a.args[j]
                    if !(headof(aa) === :punctuation)
                        mark_binding!(aa)
                    end
                end
            elseif !(headof(a) === :punctuation)
                mark_binding!(a)
            end
        end
    elseif headof(x) === :where
        for i = 3:length(x.args)
            if !(headof(x.args[i]) === :punctuation)
                mark_binding!(x.args[i])
            end
        end
        mark_sig_args!(x.args[1])
    elseif CSTParser.isbinarycall(x) || CSTParser.isbinarysyntax(x)
        op_val = CSTParser.isbinarycall(x) ? CSTParser.valof(x.args[1]) : CSTParser.valof(x.head)
        if op_val == "::"
            mark_sig_args!(x.args[1])
        else
            mark_binding!(x.args[1])
            if CSTParser.isbinarycall(x)
                mark_binding!(x.args[3])
            end
        end
    elseif CSTParser.isunarycall(x) && headof(x.args[2]) === :brackets
        mark_binding!(x.args[2].args[2])
    end
end

function mark_typealias_bindings!(x::EXPR)
    mark_binding!(x, x)
    for i = 2:length(x.args[1].args)
        if headof(x.args[1].args[i]) === :IDENTIFIER
            mark_binding!(x.args[1].args[i])
        elseif CSTParser.isbinarysyntax(x.args[1].args[i]) &&
               CSTParser.valof(x.args[1].args[i].head) == "<:" &&
               headof(x.args[1].args[i].args[1]) === :IDENTIFIER
            mark_binding!(x.args[1].args[i].args[1])
        end
    end
    return x
end
