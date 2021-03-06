"""
Evaluate an R symbol or language object (i.e. a function call) in an R
try/catch block, returning a Sxp pointer.
"""
function reval_p{S<:Sxp}(expr::Ptr{S}, env::Ptr{EnvSxp})
    err = Array(Cint,1)
    val = ccall((:R_tryEval,libR),UnknownSxpPtr,(Ptr{S},Ptr{EnvSxp},Ptr{Cint}),expr,env,err)
    if err[1] !=0
        error("RCall.jl ", readall(RCall.errorBuffer))
    elseif nb_available(errorBuffer) != 0
        warn("RCall.jl ", readall(RCall.errorBuffer))
    end
    sexp(val)
end

function reval_p(expr::Ptr{ExprSxp}, env::Ptr{EnvSxp})
    local val           # the value of the last expression is returned
    protect(expr)
    for e in expr
        val = reval_p(e,env)
    end
    unprotect(1)
    val
end

reval_p{S<:Sxp}(s::Ptr{S}) = reval_p(s,rGlobalEnv)

"""
Evaluate an R symbol or language object (i.e. a function call) in an R
try/catch block, returning an RObject.
"""
reval(s, env=rGlobalEnv) = RObject(reval_p(sexp(s),sexp(env)))
reval(str::AbstractString, env=rGlobalEnv) = reval(rparse_p(str))
reval(sym::Symbol, env=rGlobalEnv) = reval(sexp(sym))


"""
Evaluate and convert the result of a string as an R expression.
"""
rcopy(str::AbstractString) = rcopy(reval_p(rparse_p(str)))
rcopy(sym::Symbol) = rcopy(reval_p(sexp(sym)))
rcopy{T}(::Type{T}, str::AbstractString) = rcopy(T, reval_p(rparse_p(str)))
rcopy{T}(::Type{T}, sym::Symbol) = rcopy(T, reval_p(sexp(sym)))


"Parse a string as an R expression, returning a Sxp pointer."
function rparse_p(st::Ptr{StrSxp})
    status = Array(Cint,1)
    val = ccall((:R_ParseVector,libR),UnknownSxpPtr,
                (Ptr{StrSxp},Cint,Ptr{Cint},UnknownSxpPtr),
                st,-1,status,rNilValue)
    s = status[1]
    if s != 1
        s == 2 && error("RCall.jl incomplete R expression")
        s == 3 && error("RCall.jl invalid R expression")
        s == 4 && throw(EOFError())
    end
    sexp(val)
end
rparse_p(st::AbstractString) = rparse_p(sexp(st))

"Parse a string as an R expression, returning an RObject."
rparse(st::AbstractString) = RObject(rparse_p(st))


"Print the value of an Sxp using R's printing mechanism"
function rprint{S<:Sxp}(io::IO, s::Ptr{S})
    protect(s)
    # Rf_PrintValue can cause segfault if S3 objects has custom
    # print function as it doesn't use R_tryEval
    # ccall((:Rf_PrintValue,libR),Void,(Ptr{S},),s)
    # below mirrors Rf_PrintValue
    env = protect(newEnvironment(rGlobalEnv))
    env[:x] = s
    if isObject(s) || isFunction(s)
        if isS4(s)
            methodsNamespace = protect(findNamespace("methods"))
            reval(rlang_p(methodsNamespace[:show], :x),env)
            unprotect(1)
        else
            reval(rlang_p(rBaseNamespace[:print], :x),env)
        end
    else
        # Rf_PrintValueRec not found on unix!?
        # ccall((:Rf_PrintValueRec,libR),Void,(Ptr{S},Ptr{EnvSxp}),s, rGlobalEnv)
        reval(rlang_p(rBaseNamespace[symbol("print.default")], :x),env)
    end
    env[:x] = rNilValue
    write(io,takebuf_string(printBuffer))
    unprotect(2)
    nothing
end
rprint(io::IO,r::RObject) = rprint(io,r.p)

rprint(s) = rprint(STDOUT,s)



"""
Parse, evaluate and print the result of a string as an R expression.
"""
rprint(io::IO,str::ByteString) = rprint(io,reval(str))
rprint(io::IO,sym::Symbol) = rprint(io,reval(sym))

"""
Copies variables from Julia to R using the same name.
"""
macro rput(args...)
    blk = Expr(:block)
    for a in args
        if isa(a,Symbol)
            v = a
            push!(blk.args,:(rGlobalEnv[$(QuoteNode(v))] = $(esc(v))))
        elseif isa(a,Expr) && a.head == :(::)
            v = a.args[1]
            S = a.args[2]
            push!(blk.args,:(rGlobalEnv[$(QuoteNode(v))] = sexp($S,$(esc(v)))))
        else
            error("Incorrect usage of @rput")
        end
    end
    blk
end

"""
Copies variables from R to Julia using the same name.
"""
macro rget(args...)
    blk = Expr(:block)
    for a in args
        if isa(a,Symbol)
            v = a
            push!(blk.args,:($(esc(v)) = rcopy(rGlobalEnv[$(QuoteNode(v))])))
        elseif isa(a,Expr) && a.head == :(::)
            v = a.args[1]
            T = a.args[2]
            push!(blk.args,:($(esc(v)) = rcopy($(esc(T)),rGlobalEnv[$(QuoteNode(v))])))
        else
            error("Incorrect usage of @rget")
        end
    end
    blk
end
