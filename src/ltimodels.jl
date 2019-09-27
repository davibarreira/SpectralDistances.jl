const AbstractTuple = Union{Tuple, Flux.Tracker.TrackedTuple}

abstract type AbstractModel end
struct AR{T} <: AbstractModel
    a::T
    ac::T
    p::DiscreteRoots
    function AR(xo::AbstractTuple,λ=1e-2)
        a = ls(getARregressor(xo[1], xo[2]),λ) |> polyvec
        r = roots(reverse(nograd(a)))
        ac = roots2poly(log.(r))
        new{typeof(a)}(a, ac, r)
    end
    function AR(a::AbstractVector)
        r = DiscreteRoots(roots(reverse(a)))
        ac = roots2poly(log.(r))
        new{typeof(a)}(a, ac, r)
    end
end


struct ARMA{T} <: AbstractModel
    c::T
    cc::T
    a::T
    ac::T
    z::DiscreteRoots
    p::DiscreteRoots
end

ControlSystems.tf(m::AR, ts=1) = tf(1, m.a, ts)
ControlSystems.tf(m::ARMA, ts=1) = tf(m.c, m.a, ts)
PolynomialRoots.roots(m::AR) = m.p
ControlSystems.pole(m::AR) = m.p
ControlSystems.pole(m::ARMA) = m.p
ControlSystems.tzero(m::ARMA) = m.z
ControlSystems.denvec(m::AbstractModel) = m.a
ControlSystems.numvec(m::ARMA) = m.c

ControlSystems.denvec(::Discrete, m::AbstractModel) = m.a
ControlSystems.numvec(::Discrete, m::ARMA) = m.c

ControlSystems.denvec(::Continuous, m::AbstractModel) = m.ac
ControlSystems.numvec(::Continuous, m::ARMA) = m.cc

coefficients(::Discrete, m::AR) = m.a[2:end]
coefficients(::Discrete, m::ARMA) = [m.a[2:end]; m.c]
coefficients(::Continuous, m::AR) = m.ac[2:end]
coefficients(::Continuous, m::ARMA) = [m.ac[2:end]; m.cc]

function domain_transform(d::Continuous, m::AR)
    p = domain_transform(d, roots(m))
    roots2poly(p)
end


abstract type FitMethod end

fitmodel(fm,X::AbstractModel) = X

@kwdef struct PLR <: FitMethod
    nc::Int
    na::Int
    initial_order::Int = 100
    λ::Float64 = 1e-2
end
function fitmodel(fm::PLR,X::AbstractArray)
    plr(X,fm.na,fm.nc; initial_order = fm.initial_order)
end
(fm::PLR)(X) = fitmodel(fm, X)

@kwdef struct LS <: FitMethod
    na::Int
    λ::Float64 = 1e-2
end
function fitmodel(fm::LS,X::AbstractArray)
    AR(X,fm.na)
end
(fm::LS)(X) = fitmodel(fm, X)


function ls(yA::AbstractTuple,λ=1e-2)
    y,A = yA[1], yA[2]
    # (A'A + 1e-9I)\(A'y) #src
    A2 = [A; λ*I]
    (A2'A2)\(A'y)
end

AR(X::AbstractArray,order::Int,λ=1e-2) = AR((X,order),λ)

function plr(y,na,nc; initial_order = 20, λ = 1e-2)
    na >= 1 || throw(ArgumentError("na must be positive"))
    na -= 1
    y_trainA = getARregressor(y,initial_order)
    y_train,A = y_trainA[1], y_trainA[2]
    w1 = ls((y_train, A),λ)
    yhat = A*w1
    ehat = yhat - y_train
    ΔN = length(y)-length(ehat)
    y_trainA = getARXregressor(y[ΔN+1:end-1],ehat[1:end-1],na,nc)
    y_train,A = y_trainA[1], y_trainA[2]
    w = ls((y_train,A),λ)
    a,c = params2poly(w,na,nc)
    rc = roots(reverse(c))
    ra = roots(reverse(a))
    ARMA(c,roots2poly(log.(rc)),a,roots2poly(log.(ra)),rc,ra)
end

function params2poly(w,na,nb)
    a = [1; -w[1:na]]
    w = w[na+1:end]
    b = map(nb) do nb
        b = w[1:nb]
        w = w[nb+1:end]
        b
    end
    a,b
end

function toeplitz(c,r)
    @assert c[1] == r[1]
    nc = length(c)
    nr = length(r)
    A  = similar(c, nc, nr)
    A[:,1] = c
    A[1,:] = r
    for i in 2:nr
        A[2:end,i] = A[1:end-1,i-1]
    end
    A
end

function getARregressor(y, na)
    m    = na+1 # Start of yr
    n    = length(y) - m + 1 # Final length of yr
    A    = toeplitz(y[m:m+n-1],y[m:-1:m-na])
    @assert size(A,2) == na+1
    y    = A[:,1] # extract yr
    A    = A[:,2:end]
    return y,A
end

getARregressor(a::TrackedArray, b) = Flux.Tracker.track(getARregressor, a, b)

Flux.Tracker.@grad function getARregressor(y::TrackedArray,na)
    getARregressor(Flux.Tracker.data(y),na),  function (Δ)
        d = zero(y)
        d[na+1:end] .= Δ[1]
        for j in 1:size(Δ[2], 2)
            for i in 1:size(Δ[2], 1)
                di = na+1-j + i-1
                d[di] += Δ[2][i,j]
            end
        end
        (d,nothing)
    end
end


# @grad reshape(xs, dims) = reshape(data(xs), dims), Δ -> (reshape(Δ, size(xs)),nothing)
function getARXregressor(y::AbstractVector,u::AbstractVector, na, nb)
    m    = max(na,nb)+1 # Start of yr
    @assert m >= 1
    n    = length(y) - m + 1 # Final length of yr
    @assert n <= length(y)
    A    = toeplitz(y[m:m+n-1],y[m:-1:m-na])
    @assert size(A,2) == na+1
    y = A[:,1] # extract yr
    A = A[:,2:end]
    s = m-1
    A = [A toeplitz(u[s:s+n-1],u[s:-1:s-nb+1])]
    return y,A
end

getARXregressor(y::TrackedArray, u::TrackedArray, na::Int, nb::Int) = Flux.Tracker.track(getARXregressor, y, u, na, nb)

Flux.Tracker.@grad function getARXregressor(y::TrackedArray, u::TrackedArray, na::Int, nb)
    @assert nb <= na # This is not a fundamental requirement, but this adjoint does not support it yet.
    getARXregressor(Flux.Tracker.data(y),Flux.Tracker.data(u),na,nb),  function (Δ)
    dy = zero(y)
    du = zero(u)
    dy[na+1:end] .= Δ[1]
    # du[na+1:end] .= Δ[1] #src
    for j in 1:size(Δ[2], 2)
        for i in 1:size(Δ[2], 1)
            if j <= na
                dyi = na+1-j + i-1
                dy[dyi] += Δ[2][i,j]
            else
                ju = j -na
                dui = na+1-ju + i-1
                du[dui] += Δ[2][i,j]
            end
        end
    end
    (dy,du,nothing,nothing)
end
end




poly(w) = [-reverse(w); 1]
polyvec(w) = [1; -w]
polyroots(w) = roots(poly(w))

riroots(p) = (r=roots(p); (real.(r),imag.(r)))
riroots(p::TrackedArray) = Flux.Tracker.track(riroots, p)
polyroots(w::TrackedArray) = riroots(poly(w))

Flux.Tracker.@grad function riroots(p::TrackedArray)
    dp = Flux.Tracker.data(p)
    r = riroots(dp)
    r, function (Δ)
        fd = FiniteDifferences.central_fdm(3,1)
        d = FiniteDifferences.j′vp(fd, riroots, Δ, dp)
        (d,)
    end
end

function d2c(a,c=1)
    error("This method should go")
    @assert a[1] == 1 "Convert to polynomial first"
    Gd = ss(tf(c,a,1))
    n = Gd.nx
    Md = [Gd.A Gd.B; zeros(1,n) 1]
    Mc = log(Md)
    Ac = Mc[1:n, 1:n]
    e = eigvals(Ac)
    e
end

function roots2polyold(roots)
    p = [1.]
    for r in roots
        p = DSP.conv(p, [1.,-r])
    end
    real(p)
end

using StaticArrays

function roots2poly(roots)
    p = @MVector [1.]
    for r in 1:length(roots)
        p = roots2poly_kernel(p, roots[r])
    end
    real(p)
end

function roots2poly_kernel(a::Union{StaticVector{N,T},StaticVector{N,T}},b) where {N,T<:Real}
    c = MVector{N+1,Complex{T}}(ntuple(_->0, N+1))
    c[1] = 1
    for i in 2:length(a)
        c[i] = -b*a[i-1] + a[i]
    end
    c[end] = -b*a[end]
    c
end

function roots2poly_kernel(a::Union{StaticVector{N,T},StaticVector{N,T}},b) where {N,T<:Complex}
    c = MVector{N+1,T}(ntuple(_->0, N+1))
    c[1] = 1
    for i in 2:length(a)
        c[i] = -b*a[i-1] + a[i]
    end
    c[end] = -b*a[end]
    c
end

# roots2poly([-1,-2,-3])


# function PolynomialRoots.roots(poly::AbstractVector{<:N}; epsilon::AbstractFloat=NaN,
#     polish::Bool=false) where {N}
#     degree = length(poly) - 1
#     PolynomialRoots.roots!(zeros(Complex{real((N))}, degree), (complex(poly)),
#     epsilon, degree, polish)
# end
#
# function PolynomialRoots.roots!(roots::AbstractVector{<:Complex{T}}, poly::AbstractVector{<:Complex{T}}, epsilon::E,
#     degree::Integer, polish::Bool) where {T<:Union{AbstractFloat, AbstractParticles},E<:Union{AbstractFloat, AbstractParticles}}
#     isnan(epsilon) && (epsilon = eps(T))
#     poly2 = copy(poly)
#     if degree <= 1
#         if degree == 1
#             roots[1] = -poly[1] / poly[2]
#         end
#         return roots
#     end
#     @inbounds for n = degree:-1:3
#         roots[n], iter, success = PolynomialRoots.laguerre2newton(poly2, n, roots[n], 2, epsilon)
#         if ! success
#             roots[n], iter, success = PolynomialRoots.laguerre(poly2, n,
#             zero(Complex{T}), epsilon)
#         end
#         coef = poly2[n+1]
#         @inbounds for i = n:-1:1
#             prev = poly2[i]
#             poly2[i] = coef
#             coef = prev + roots[n]*coef
#         end
#     end
#     roots[1], roots[2] = PolynomialRoots.solve_quadratic_eq(poly2)
#     if polish
#         @inbounds for n = 1:degree # polish roots one-by-one with a full polynomial
#             roots[n], iter, success = PolynomialRoots.laguerre(poly, degree, roots[n], epsilon)
#         end
#     end
#     return roots
# end
