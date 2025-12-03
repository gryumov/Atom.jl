#=
Scope information for `EXRR`.

NOTE:
- StaticLint.jl adds various scope-related information for `EXPR.meta.scope` field,
    but we currently just need to know whether `EXPR` introduces a scope or not.
    So let's just make a function to check that, and don't fill `EXPR` with scope information.
- Adapted from https://github.com/julia-vscode/StaticLint.jl/blob/cd8935a138caf18385c46db977b52c5ac9e90809/src/scope.jl
=#

function hasscope(x::EXPR)
    t = headof(x)

    # NOTE: added conditions below when adapted
    if t === :tuple && (p = parentof(x)) !== nothing && !hasscope(p)
        return true
    elseif iswhereclause(x)
        return true
    elseif t === :macrocall
        return true
    elseif t === :quote
        return true
    # NOTE: end

    elseif CSTParser.isbinarycall(x) || CSTParser.isbinarysyntax(x)
        op_val = CSTParser.isbinarycall(x) ? CSTParser.valof(x.args[1]) : CSTParser.valof(x.head)
        if op_val == "=" && CSTParser.is_func_call(x.args[1])
            return true
        elseif op_val == "=" && headof(x.args[1]) === :curly
            return true
        elseif op_val == "->"
            return true
        else
            return false
        end
    # # NOTE: commented out when adapted
    # elseif t === CSTParser.WhereOpCall
    #     # unless in func def signature
    #     return !_in_func_def(x)
    elseif t === :function ||
           t === :macro ||
           t === :for ||
           t === :while ||
           t === :let ||
           t === :generator || # and Flatten?
           t === :try ||
           t === :do ||
           t === :module ||
           t === :baremodule ||
           t === :abstract ||
           t === :primitive ||
           t === :mutable ||
           t === :struct
        return true
    end

    return false
end

# # NOTE: commented out when adapted
# # only called in WhereOpCall
# function _in_func_def(x::EXPR)
#     # check 1st arg contains a call (or op call)
#     ex = x.args[1]
#     while true
#         if headof(ex) === CSTParser.WhereOpCall ||
#            (
#             headof(ex) === CSTParser.BinaryOpCall &&
#             kindof(ex.args[2]) === CSTParser.Tokens.DECLARATION
#            )
#             ex = ex.args[1]
#         elseif headof(ex) === CSTParser.Call ||
#                (
#                 headof(ex) === CSTParser.BinaryOpCall &&
#                 !(kindof(ex.args[2]) === CSTParser.Tokens.DOT)
#                ) ||
#                headof(ex) == CSTParser.UnaryOpCall #&& kindof(ex.args[1]) == CSTParser.Tokens.MINUS
#             break
#         else
#             return false
#         end
#     end
#     # check parent is func def
#     ex = x
#     while true
#         if !(parentof(ex) isa EXPR)
#             return false
#         elseif headof(parentof(ex)) === CSTParser.WhereOpCall ||
#                headof(parentof(ex)) === CSTParser.InvisBrackets
#             ex = parentof(ex)
#         elseif headof(parentof(ex)) === CSTParser.FunctionDef ||
#                (
#                 headof(parentof(ex)) === CSTParser.BinaryOpCall &&
#                 kindof(parentof(ex).args[2]) === CSTParser.Tokens.EQ
#                )
#             return true
#         else
#             return false
#         end
#     end
#     return false
# end
