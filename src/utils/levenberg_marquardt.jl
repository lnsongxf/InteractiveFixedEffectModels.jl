
##############################################################################
##
## 
##############################################################################

const MAX_λ = 1e16 # minimum trust region radius
const MIN_λ = 1e-16 # maximum trust region radius
const MIN_STEP_QUALITY = 1e-3
const GOOD_STEP_QUALITY = 0.75
const MIN_DIAGONAL = 1e-6

function levenberg_marquardt!(x, fg, fcur, f!, g!; 
                              tol::Real = 1e-8, maxiter::Integer = 1000, λ::Real = 10.0)
    converged = false
    iterations = maxiter
    need_jacobian = true

    δx = similar(x)
    dtd = similar(x)
    ftrial = similar(fcur)
    ftmp = similar(fcur)

    # for lsmr
    alloc = ls_solver_alloc(fg, x, fcur)
    # initialize
    f!(x, fcur)
    mfcur = scale!(fcur, -1.0)
    residual = sumabs2(mfcur)
    iter = 0
    while iter < maxiter 
        iter += 1
        if need_jacobian
            g!(x, fg)
            need_jacobian = false
        end
        sumabs2!(dtd, fg)
        # solve (J'J + λ * diagm(dtd)) = -J'fcur
        fill!(δx, zero(Float64))
        currentiter = ls_solver!(δx, mfcur, fg, dtd, λ, alloc)
        iter += currentiter
        # predicted residual
        copy!(ftmp, mfcur)
        A_mul_B!(1.0, fg, δx, -1.0, ftmp)
        predicted_residual = sumabs2(ftmp)
        # trial residual
        axpy!(1.0, δx, x)
        f!(x, ftrial)
        trial_residual = sumabs2(ftrial)
        ρ = (residual - trial_residual) / (residual - predicted_residual)
        if ρ > GOOD_STEP_QUALITY
            scale!(mfcur, ftrial, -1.0)
            residual = trial_residual
            # increase trust region radius
            if ρ > 0.75
                λ = max(0.1 * λ, MIN_λ)
            end
            need_jacobian = true
        else
            # revert update
            axpy!(-1.0, δx, x)
            λ = min(10 * λ, MAX_λ)
        end
        if maxabs(δx) < tol
            iterations = iter
            converged = true
            break
        end
    end
    return iterations, converged
end

##############################################################################
## 
## Dense Matrix
##
##############################################################################

function ls_solver_alloc{T}(fg::Matrix{T}, x::Vector{T}, mfcur::Vector{T})
    M = Array(T, size(fg, 1), size(fg, 1))
    rhs = Array(T, size(fg, 1))
end

function ls_solver!{T}(δx::Vector{T}, mfcur::Vector{T}, fg::Matrix{T}, dtd::Vector{T}, λ, alloc)
    clamp!(dtd, MIN_DIAGONAL, Inf)
    scale!(dtd, λ^2)
    M, rhs = alloc

    # update M as J'J + λ^2dtd
    At_mul_B(fg, fg, alloc.M)
    for i in 1:size(alloc.M)
        alloc.M[i, i] += dtd
    end
    # update rhs as J' fcur
    At_mul_B(alloc.fg, mfcur, alloc.rhs)
    A_ldiv_B!(δx, alloc.M, alloc.rhs)
    return 1
end

##############################################################################
## 
## Case where J'J is costly to store: Sparse Matrix, but really anything
## that defines 
## A_mul_B(α, A, a, β b) that updates b as α A a + β b 
## Ac_mul_B(α, A, a, β b) that updates b as α A' a + β b 
##
## An Inexact Levenberg Marquardt Method for Large Sparse Nonlinear Least Squares
## SJ Wright and J.N. Holt
# we use LSMR with the matrix A = |J         |
#                                 |diag(dtd) |
# and 1/sqrt(diag(A'A)) as preconditioner
##
##############################################################################


# We need to define functions used in LSMR on this augmented space
type MatrixWrapper{TA, Tx}
    A::TA # J
    d::Tx # λ * sqrt(diag(J'J))
    normalization::Tx # (1 + λ^2 diag(J'J))
    tmp::Tx
end

type VectorWrapper{Ty, Tx}
    y::Ty # dimension of f(x)
    x::Tx # dimension of x
end

# These functions are used in lsmr (ducktyping)
function copy!{Ty, Tx}(a::VectorWrapper{Ty, Tx}, b::VectorWrapper{Ty, Tx})
    copy!(a.y, b.y)
    copy!(a.x, b.x)
    return a
end

function fill!(a::VectorWrapper, α)
    fill!(a.y, α)
    fill!(a.x, α)
    return a
end

function scale!(a::VectorWrapper, α)
    scale!(a.y, α)
    scale!(a.x, α)
    return a
end

function axpy!{Ty, Tx}(α, a::VectorWrapper{Ty, Tx}, b::VectorWrapper{Ty, Tx})
    axpy!(α, a.y, b.y)
    axpy!(α, a.x, b.x)
    return b
end

function norm(a::VectorWrapper)
    return sqrt(norm(a.y)^2 + norm(a.x)^2)
end

function A_mul_B!{TA, Tx, Ty}(α::Float64, mw::MatrixWrapper{TA, Tx}, a::Tx, 
                β::Float64, b::VectorWrapper{Ty, Tx})
    map!((x, z) -> x / sqrt(z), mw.tmp, a, mw.normalization)
    A_mul_B!(α, mw.A, mw.tmp, β, b.y)
    map!((z, x, y)-> β * z + α * x * y, b.x, b.x, mw.tmp, mw.d)
    return b
end

function Ac_mul_B!{TA, Tx, Ty}(α::Float64, mw::MatrixWrapper{TA, Tx}, a::VectorWrapper{Ty, Tx}, 
                β::Float64, b::Tx)
    Ac_mul_B!(α, mw.A, a.y, 0.0, mw.tmp)
    map!((z, x, y)-> z + α * x * y, mw.tmp, mw.tmp, a.x, mw.d)
    map!((x, z) -> x / sqrt(z), mw.tmp, mw.tmp, mw.normalization)
    axpy!(β, b, mw.tmp)
    copy!(b, mw.tmp)
    return b
end

function ls_solver_alloc(fg, x, fcur)
    normalization = similar(x)
    zerosvector = similar(x)
    fill!(zerosvector, zero(Float64))
    u = VectorWrapper(similar(fcur), similar(x))
    v = similar(x)
    h = similar(x)
    hbar = similar(x)
    xtmp = similar(x)
    return normalization, zerosvector, u, v, h, hbar, xtmp
end

function ls_solver!(δx, mfcur, fg, dtd, λ, alloc)
    # we use LSMR with the matrix A = |J         |
    #                                 |diag(dtd) |
    # and 1/sqrt(diag(A'A)) as preconditioner
    normalization, zerosvector, u, v, h, hbar, xtmp = alloc
    copy!(normalization, dtd)
    clamp!(dtd, MIN_DIAGONAL, Inf)
    scale!(dtd, λ^2)
    axpy!(1.0, dtd, normalization)
    map!(sqrt, dtd, dtd)
    y = VectorWrapper(mfcur, zerosvector)
    A = MatrixWrapper(fg, dtd, normalization, xtmp)
    iter = lsmr!(δx, y, A, u, v, h, hbar)
    map!((x, z) -> x / sqrt(z), δx, δx, normalization)
    return iter
end

## LSMR
##
## Minimize ||Ax-b||^2 + λ^2 ||x||^2
##
## Arguments:
## x is initial x0. Will equal the solution.
## r is initial b - Ax0
## u is storage arrays of length size(A, 1) == length(b)
## v, h, hbar are storage arrays of length size(A, 2) == length(x)
## 
## Adapted from the BSD-licensed Matlab implementation at
##  http://web.stanford.edu/group/SOL/software/lsmr/
##
## A is anything such that
## A_mul_B!(α, A, b, β, c) updates c -> α Ab + βc
## Ac_mul_B!(α, A, b, β, c) updates c -> α A'b + βc


function lsmr!(x, r, A, u, v, h, hbar; 
    atol = 1e-10, btol = 1e-10, conlim = 1e10, maxiter::Integer=100, λ::Real = zero(Float64))

    conlim > 0.0 ? ctol = 1 / conlim : ctol = zero(Float64)

    # form the first vectors u and v (satisfy  β*u = b,  α*v = A'u)
    copy!(u, r)
    β = norm(u)
    β > 0 && scale!(u, 1/β)
    Ac_mul_B!(1.0, A, u, 0.0, v)
    α = norm(v)
    α > 0 && scale!(v, 1/α)

    # Initialize variables for 1st iteration.
    ζbar = α * β
    αbar = α
    ρ = one(Float64)
    ρbar = one(Float64)
    cbar = one(Float64)
    sbar = zero(Float64)

    copy!(h, v)
    fill!(hbar, zero(Float64))

    # Initialize variables for estimation of ||r||.
    βdd = β
    βd = zero(Float64)
    ρdold = one(Float64)
    τtildeold = zero(Float64)
    θtilde  = zero(Float64)
    ζ = zero(Float64)
    d = zero(Float64)

    # Initialize variables for estimation of ||A|| and cond(A).
    normA2 = α^2
    maxrbar = zero(Float64)
    minrbar = 1e100

    # Items for use in stopping rules.
    normb = β
    istop = 7
    normr = β

    # Exit if b = 0 or A'b = zero(Float64).
    normAr = α * β
    if normAr == zero(Float64) 
        return 1, true
    end

    iter = 0
    while iter < maxiter
        iter += 1
        A_mul_B!(1.0, A, v, -α, u)
        β = norm(u)
        if β > 0
            scale!(u, 1/β)
            Ac_mul_B!(1.0, A, u, -β, v)
            α = norm(v)
            α > 0 && scale!(v, 1/α)
        end

        # Construct rotation Qhat_{k,2k+1}.
        αhat = sqrt(αbar^2 + λ^2)
        chat = αbar / αhat
        shat = λ / αhat

        # Use a plane rotation (Q_i) to turn B_i to R_i.
        ρold = ρ
        ρ = sqrt(αhat^2 + β^2)
        c = αhat / ρ
        s = β / ρ
        θnew = s * α
        αbar = c * α

        # Use a plane rotation (Qbar_i) to turn R_i^T to R_i^bar.
        ρbarold = ρbar
        ζold = ζ
        θbar = sbar * ρ
        ρtemp = cbar * ρ
        ρbar = sqrt(cbar^2 * ρ^2 + θnew^2)
        cbar = cbar * ρ / ρbar
        sbar = θnew / ρbar
        ζ = cbar * ζbar
        ζbar = - sbar * ζbar

        # Update h, h_hat, x.
        scale!(hbar, - θbar * ρ / (ρold * ρbarold))
        axpy!(1.0, h, hbar)
        axpy!(ζ / (ρ * ρbar), hbar, x)
        scale!(h, - θnew / ρ)
        axpy!(1.0, v, h)

        ##############################################################################
        ##
        ## Estimate of ||r||
        ##
        ##############################################################################

        # Apply rotation Qhat_{k,2k+1}.
        βacute = chat * βdd
        βcheck = - shat * βdd

        # Apply rotation Q_{k,k+1}.
        βhat = c * βacute
        βdd = - s * βacute
          
        # Apply rotation Qtilde_{k-1}.
        θtildeold = θtilde
        ρtildeold = sqrt(ρdold^2 + θbar^2)
        ctildeold = ρdold / ρtildeold
        stildeold = θbar / ρtildeold
        θtilde = stildeold * ρbar
        ρdold = ctildeold * ρbar
        βd = - stildeold * βd + ctildeold * βhat

        τtildeold = (ζold - θtildeold * τtildeold) / ρtildeold
        τd = (ζ - θtilde * τtildeold) / ρdold
        d  = d + βcheck^2
        normr = sqrt(d + (βd - τd)^2 + βdd^2)

        # Estimate ||A||.
        normA2 = normA2 + β^2
        normA  = sqrt(normA2)
        normA2 = normA2 + α^2

        # Estimate cond(A).
        maxrbar = max(maxrbar, ρbarold)
        if iter > 1 
            minrbar = min(minrbar, ρbarold)
        end
        condA = max(maxrbar, ρtemp) / min(minrbar, ρtemp)
        ##############################################################################
        ##
        ## Test for convergence
        ##
        ##############################################################################

        # Compute norms for convergence testing.
        normAr  = abs(ζbar)
        normx = norm(x)

        # Now use these norms to estimate certain other quantities,
        # some of which will be small near a solution.
        test1 = normr / normb
        test2 = normAr / (normA * normr)
        test3 = 1 / condA
        t1 = test1 / (1 + normA * normx / normb)
        rtol = btol + atol * normA * normx / normb

        # The following tests guard against extremely small values of
        # atol, btol or ctol.  (The user may have set any or all of
        # the parameters atol, btol, conlim  to 0.)
        # The effect is equivalent to the normAl tests using
        # atol = eps,  btol = eps,  conlim = one(Float64)/eps.
        if 1 + test3 <= one(Float64) istop = 6; break end
        if 1 + test2 <= one(Float64) istop = 5; break end
        if 1 + t1 <= one(Float64) istop = 4; break end

        # Allow for tolerances set by the user.
        if test3 <= ctol istop = 3; break end
        if test2 <= atol istop = 2; break end
        if test1 <= rtol  istop = 1; break end
    end
    return iter
end
        