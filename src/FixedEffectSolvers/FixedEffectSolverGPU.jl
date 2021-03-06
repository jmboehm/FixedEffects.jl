using CuArrays.CUDAnative
import CuArrays: allowscalar
allowscalar(false)

##############################################################################
##
## Conversion FixedEffect between CPU and GPU
##
##############################################################################

# https://github.com/JuliaGPU/CuArrays.jl/issues/306
cuzeros(T::Type, n::Integer) = fill!(CuVector{T}(undef, n), zero(T))
function CuArrays.cu(T::Type, fe::FixedEffect)
	refs = CuArray(fe.refs)
	interaction = cu(T, fe.interaction)
	FixedEffect{typeof(refs), typeof(interaction)}(refs, interaction, fe.n)
end
CuArrays.cu(T::Type, w::Union{Fill, Ones, Zeros}) = fill!(CuVector{T}(undef, length(w)), w[1])
CuArrays.cu(T::Type, w::AbstractVector) = CuVector{T}(w)

##############################################################################
##
## FixedEffectLinearMap on the GPU (code by Paul Schrimpf)
##
## Model matrix of categorical variables
## mutiplied by diag(1/sqrt(∑w * interaction^2, ..., ∑w * interaction^2) (Jacobi preconditoner)
##
## We define these methods used in lsmr! (duck typing):
## eltyp
## size
## mul!
##
##############################################################################

mutable struct FixedEffectLinearMapGPU{T}
	fes::Vector{<:FixedEffect}
	colnorm::Vector{<:AbstractVector}
	caches::Vector{<:AbstractVector}
	nthreads::Int
end

function FixedEffectLinearMapGPU{T}(fes::Vector{<:FixedEffect}, weights::AbstractWeights, ::Type{Val{:gpu}}) where {T}
	nthreads = 256
	fes = [cu(T, fe) for fe in fes]
	sqrtw = cu(T, sqrt.(values(weights)))
	colnorm = [_colnorm!(cuzeros(T, fe.n), fe.refs, fe.interaction, sqrtw, nthreads) for fe in fes]
	caches = [_cache!(cuzeros(T, length(sqrtw)), fe.interaction, sqrtw, scale, fe.refs, nthreads) for (fe, scale) in zip(fes, colnorm)]
	return FixedEffectLinearMapGPU{T}(fes, colnorm, caches, nthreads)
end

function _colnorm!(fecoef::CuVector, refs::CuVector, y::CuVector, sqrtw::CuVector, nthreads::Integer)
	nblocks = cld(length(refs), nthreads) 
	@cuda threads=nthreads blocks=nblocks _colnorm!_kernel!(fecoef, refs, y, sqrtw)
	fecoef .= sqrt.(fecoef)
end

function _colnorm!_kernel!(fecoef, refs, y, sqrtw)
	index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
	stride = blockDim().x * gridDim().x
	@inbounds for i = index:stride:length(y)
		CuArrays.CUDAnative.atomic_add!(pointer(fecoef, refs[i]), abs2(y[i] * sqrtw[i]))
	end
end

function _cache!(y::CuVector, interaction::CuVector , sqrtw::CuVector, fecoef::CuVector, refs::CuVector, nthreads::Integer)
	nblocks = cld(length(y), nthreads) 
	@cuda threads=nthreads blocks=nblocks _cache_kernel!(y, interaction, sqrtw, fecoef, refs)
	return y
end

function _cache_kernel!(y, interaction, sqrtw, fecoef, refs)
	index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
	stride = blockDim().x * gridDim().x
	@inbounds for i = index:stride:length(y)
		y[i] += interaction[i] * sqrtw[i] / fecoef[refs[i]]
	end
end

LinearAlgebra.adjoint(fem::FixedEffectLinearMapGPU) = Adjoint(fem)

function Base.size(fem::FixedEffectLinearMapGPU, dim::Integer)
	(dim == 1) ? length(fem.fes[1].refs) : (dim == 2) ? sum(fe.n for fe in fem.fes) : 1
end

Base.eltype(x::FixedEffectLinearMapGPU{T}) where {T} = T

function LinearAlgebra.mul!(fecoefs::FixedEffectCoefficients, 
	Cfem::Adjoint{T, FixedEffectLinearMapGPU{T}},
	y::AbstractVector, α::Number, β::Number) where {T}
	fem = adjoint(Cfem)
	rmul!(fecoefs, β)
	for (fecoef, fe, cache) in zip(fecoefs.x, fem.fes, fem.caches)
		_mean!(fecoef, fe.refs, α, y, cache, fem.nthreads)
	end
	return fecoefs
end


function _mean!(fecoef::CuVector, refs::CuVector, α::Number, y::CuVector, cache::CuVector, nthreads::Integer)
	nblocks = cld(length(y), nthreads) 
	@cuda threads=nthreads blocks=nblocks _mean_kernel!(fecoef, refs, α, y, cache)    
end

function _mean_kernel!(fecoef, refs, α, y, cache)
	index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
	stride = blockDim().x * gridDim().x
	@inbounds for i = index:stride:length(y)
		CuArrays.CUDAnative.atomic_add!(pointer(fecoef, refs[i]), α * y[i] * cache[i])
	end
end


function LinearAlgebra.mul!(y::AbstractVector, fem::FixedEffectLinearMapGPU, 
			  fecoefs::FixedEffectCoefficients, α::Number, β::Number)
	rmul!(y, β)
	for (fecoef, fe, cache) in zip(fecoefs.x, fem.fes, fem.caches)
		_demean!(y, α, fecoef, fe.refs, cache, fem.nthreads)
	end
	return y
end

function _demean!(y::CuVector, α::Number, fecoef::CuVector, refs::CuVector, cache::CuVector, nthreads::Integer)
	nblocks = cld(length(y), nthreads)
	@cuda threads=nthreads blocks=nblocks _demean_kernel!(y, α, fecoef, refs, cache)
end

function _demean_kernel!(y, α, fecoef, refs, cache)
	index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
	stride = blockDim().x * gridDim().x
	@inbounds for i = index:stride:length(y)
		y[i] += α * fecoef[refs[i]] * cache[i]
	end
end

##############################################################################
##
## Implement AbstractFixedEffectSolver interface
##
##############################################################################

struct FixedEffectSolverGPU{T} <: AbstractFixedEffectSolver{T}
	m::FixedEffectLinearMapGPU{T}
	sqrtw::CuVector{T}
	b::CuVector{T}
	r::CuVector{T}
	x::FixedEffectCoefficients{T}
	v::FixedEffectCoefficients{T}
	h::FixedEffectCoefficients{T}
	hbar::FixedEffectCoefficients{T}
	tmp::Vector{T} # used to convert AbstractVector to Vector{T}
	fes::Vector{<:FixedEffect}
end
	
function AbstractFixedEffectSolver{T}(fes::Vector{<:FixedEffect}, weights::AbstractWeights, ::Type{Val{:gpu}}) where {T}
	m = FixedEffectLinearMapGPU{T}(fes, weights, Val{:gpu})
	sqrtw = cu(T, sqrt.(values(weights)))
	b = cuzeros(T, length(weights))
	r = cuzeros(T, length(weights))
	x = FixedEffectCoefficients([cuzeros(T, fe.n) for fe in fes])
	v = FixedEffectCoefficients([cuzeros(T, fe.n) for fe in fes])
	h = FixedEffectCoefficients([cuzeros(T, fe.n) for fe in fes])
	hbar = FixedEffectCoefficients([cuzeros(T, fe.n) for fe in fes])
	tmp = zeros(T, length(weights))
	FixedEffectSolverGPU{T}(m, sqrtw, b, r, x, v, h, hbar, tmp, fes)
end

function solve_residuals!(r::AbstractVector, feM::FixedEffectSolverGPU{T}; tol::Real = sqrt(eps(T)), maxiter::Integer = 100_000) where {T}
	copyto!(feM.tmp, r)
	copyto!(feM.r, feM.tmp)
	feM.r .*=  feM.sqrtw
	copyto!(feM.b, feM.r)
	fill!(feM.x, 0.0)
	x, ch = lsmr!(feM.x, feM.m, feM.b, feM.v, feM.h, feM.hbar; atol = tol, btol = tol, maxiter = maxiter)
	mul!(feM.r, feM.m, feM.x, -1.0, 1.0)
	feM.r ./=  feM.sqrtw
	copyto!(feM.tmp, feM.r)
	copyto!(r, feM.tmp)
	return r, div(ch.mvps, 2), ch.isconverged
end

function FixedEffects.solve_residuals!(X::AbstractMatrix, feM::FixedEffects.FixedEffectSolverGPU; kwargs...)
    iterations = Int[]
    convergeds = Bool[]
    for j in 1:size(X, 2)
        _, iteration, converged = solve_residuals!(view(X, :, j), feM; kwargs...)
        push!(iterations, iteration)
        push!(convergeds, converged)
    end
    return X, iterations, convergeds
end

function solve_coefficients!(r::AbstractVector, feM::FixedEffectSolverGPU{T}; tol::Real = sqrt(eps(T)), maxiter::Integer = 100_000) where {T}
	copyto!(feM.tmp, r)
	copyto!(feM.b, feM.tmp)
	feM.b .*= feM.sqrtw
	fill!(feM.x, 0.0)
	x, ch = lsmr!(feM.x, feM.m, feM.b, feM.v, feM.h, feM.hbar; atol = tol, btol = tol, maxiter = maxiter)
	for (x, scale) in zip(feM.x.x, feM.m.colnorm)
		x ./=  scale
	end
	x = Vector{eltype(r)}[collect(x) for x in feM.x.x]
	full(normalize!(x, feM.fes; tol = tol, maxiter = maxiter), feM.fes), div(ch.mvps, 2), ch.isconverged
end