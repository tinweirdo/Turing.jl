##############################
# Global variables/constants #
##############################

const ADBACKEND = Ref(:forward_diff)
setadbackend(backend_sym::Symbol) = setadbackend(Val(backend_sym))
function setadbackend(::Val{:forward_diff})
    CHUNKSIZE[] == 0 && setchunksize(40)
    ADBACKEND[] = :forward_diff
end
function setadbackend(::Val{:reverse_diff})
    ADBACKEND[] = :reverse_diff
end

const ADSAFE = Ref(false)
function setadsafe(switch::Bool)
    @info("[Turing]: global ADSAFE is set as $switch")
    ADSAFE[] = switch
end

const CHUNKSIZE = Ref(40) # default chunksize used by AD

function setchunksize(chunk_size::Int)
    if ~(CHUNKSIZE[] == chunk_size)
        @info("[Turing]: AD chunk size is set as $chunk_size")
        CHUNKSIZE[] = chunk_size
    end
end

abstract type ADBackend end
struct ForwardDiffAD{chunk} <: ADBackend end
getchunksize(::Type{<:ForwardDiffAD{chunk}}) where chunk = chunk
getchunksize(::Type{<:Sampler{Talg}}) where Talg = getchunksize(Talg)
getchunksize(::Type{SampleFromPrior}) = CHUNKSIZE[]

struct TrackerAD <: ADBackend end

ADBackend() = ADBackend(ADBACKEND[])
ADBackend(T::Symbol) = ADBackend(Val(T))

ADBackend(::Val{:forward_diff}) = ForwardDiffAD{CHUNKSIZE[]}
ADBackend(::Val{:reverse_diff}) = TrackerAD
ADBackend(::Val) = error("The requested AD backend is not available. Make sure to load all required packages.")

"""
getADtype(alg)

Finds the autodifferentiation type of the algorithm `alg`.
"""
getADtype(spl::Sampler) = getADtype(spl.alg)

"""
gradient_logp(
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    sampler::AbstractSampler=SampleFromPrior(),
)

Computes the value of the log joint of `θ` and its gradient for the model
specified by `(vi, sampler, model)` using whichever automatic differentation
tool is currently active.
"""
function gradient_logp(
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    sampler::Sampler
)
    ad_type = getADtype(sampler)
    if ad_type <: ForwardDiffAD
        return gradient_logp_forward(θ, vi, model, sampler)
    else
        return gradient_logp_reverse(ad_type(), θ, vi, model, sampler)
    end
end

"""
gradient_logp_forward(
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    spl::AbstractSampler=SampleFromPrior(),
)

Computes the value of the log joint of `θ` and its gradient for the model
specified by `(vi, spl, model)` using forwards-mode AD from ForwardDiff.jl.
"""
function gradient_logp_forward(
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    sampler::AbstractSampler=SampleFromPrior(),
)
    # Define function to compute log joint.
    logp_old = getlogp(vi)
    function f(θ)
        new_vi = VarInfo(vi, sampler, θ)
        logp = getlogp(runmodel!(model, new_vi, sampler))
        setlogp!(vi, ForwardDiff.value(logp))
        return logp
    end

    chunk_size = getchunksize(typeof(sampler))
    # Set chunk size and do ForwardMode.
    chunk = ForwardDiff.Chunk(min(length(θ), chunk_size))
    config = ForwardDiff.GradientConfig(f, θ, chunk)
    ∂l∂θ = ForwardDiff.gradient!(similar(θ), f, θ, config)
    l = getlogp(vi)
    setlogp!(vi, logp_old)

    return l, ∂l∂θ
end

"""
gradient_logp_reverse(
    backend::ADBackend,
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    sampler::AbstractSampler = SampleFromPrior(),
)

Computes the value of the log joint of `θ` and its gradient for the model
specified by `(vi, sampler, model)` using reverse-mode AD from the specified `backend`, e.g. `TrackerAD()` which uses `Tracker.jl` or `ZygoteAD()` which uses `Zygote.jl`.
"""
function gradient_logp_reverse(
    backend::TrackerAD,
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    sampler::AbstractSampler = SampleFromPrior(),
)
    T = typeof(getlogp(vi))

    # Specify objective function.
    function f(θ)
        new_vi = VarInfo(vi, sampler, θ)
        return getlogp(runmodel!(model, new_vi, sampler))
    end

    # Compute forward and reverse passes.
    l_tracked, ȳ = Tracker.forward(f, θ)
    # Remove tracking info from variables in model (because mutable state).
    l::T, ∂l∂θ::typeof(θ) = Tracker.data(l_tracked), Tracker.data(ȳ(1)[1])

    return l, ∂l∂θ
end
function gradient_logp_reverse(
    θ::AbstractVector{<:Real},
    vi::VarInfo,
    model::Model,
    sampler::AbstractSampler = SampleFromPrior(),
)
    return gradient_logp_reverse(TrackerAD(), θ, vi, model, sampler)
end

function verifygrad(grad::AbstractVector{<:Real})
    if any(isnan, grad) || any(isinf, grad)
        @warn("Numerical error in gradients. Rejecting current proposal...")
        @warn("grad = $(grad)")
        return false
    else
        return true
    end
end

# Replace the adjoints below with Zygote ones
for F in (:link, :invlink)
    @eval begin
        function $F(
            dist::Dirichlet, 
            x::Tracker.TrackedArray, 
            ::Type{Val{proj}} = Val{true}
        ) where {proj}
            return Tracker.track($F, dist, x, Val{proj})
        end
        Tracker.@grad function $F(
            dist::Dirichlet, 
            x::Tracker.TrackedArray, 
            ::Type{Val{proj}}
        ) where {proj}
            x_data = Tracker.data(x)
            T = eltype(x_data)
            y = $F(dist, x_data, Val{proj})
            return  y, Δ -> begin
                out = reshape((ForwardDiff.jacobian(x -> $F(dist, x, Val{proj}), x_data)::Matrix{T})' * vec(Δ), size(Δ))
                return (nothing, out, nothing)
            end
        end
    end
end

for F in (:link, :invlink)
    @eval begin
        $F(dist::PDMatDistribution, x::Tracker.TrackedArray) = Tracker.track($F, dist, x)
        Tracker.@grad function $F(dist::PDMatDistribution, x::Tracker.TrackedArray)
            x_data = Tracker.data(x)
            T = eltype(x_data)
            y = $F(dist, x_data)
            return  y, Δ -> begin
                out = reshape((ForwardDiff.jacobian(x -> $F(dist, x), x_data)::Matrix{T})' * vec(Δ), size(Δ))
                return (nothing, out)
            end
        end
    end
end
