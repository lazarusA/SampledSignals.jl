using Base.Broadcast: Broadcasted, ArrayStyle

abstract type AbstractSampleBuf{T, N} <: AbstractArray{T, N} end

"""
Represents a multi-channel regularly-sampled buffer that stores its own sample
rate (in samples/second). The wrapped data is an N-dimensional array. A 1-channel
sample can be represented with a 1D array or an Mx1 matrix, and a C-channel
buffer will be an MxC matrix. So a 1-second stereo audio buffer sampled at
44100Hz with 32-bit floating-point samples in the time domain would have the
type SampleBuf{Float32, 2}.
"""
mutable struct SampleBuf{T, N} <: AbstractSampleBuf{T, N}
    data::Array{T, N}
    samplerate::Float64
end

# define constructor so conversion is applied to `sr`
SampleBuf(arr::Array{T, N}, sr::Real) where {T, N} = SampleBuf{T, N}(arr, sr)

"""
Represents a multi-channel regularly-sampled buffer representing the frequency-
domain spectrum of a `SampleBuf`. The wrapped data is an N-dimensional array. A
1-channel sample can be represented with a 1D array or an Mx1 matrix, and a
C-channel buffer will be an MxC matrix. So a 1-second stereo audio buffer
sampled at 44100Hz with 32-bit floating-point samples in the time domain would
have the type SampleBuf{Float32, 2}.
"""
mutable struct SpectrumBuf{T, N} <: AbstractSampleBuf{T, N}
    data::Array{T, N}
    samplerate::Float64
end

# define constructor so conversion is applied to `sr`
SpectrumBuf(arr::Array{T, N}, sr::Real) where {T, N} = SpectrumBuf{T, N}(arr, sr)

SampleBuf(T::Type, sr, dims...) = SampleBuf(Array{T}(undef, dims...), sr)
SpectrumBuf(T::Type, sr, dims...) = SpectrumBuf(Array{T}(undef, dims...), sr)
SampleBuf(T::Type, sr, len::Quantity) = SampleBuf(T, sr, inframes(Int,len,sr))
SampleBuf(T::Type, sr, len::Quantity, ch) =
    SampleBuf(T, sr, inframes(Int,len,sr), ch)
SpectrumBuf(T::Type, sr, len::Quantity) =
    SpectrumBuf(T, sr, inframes(Int,len, sr))
SpectrumBuf(T::Type, sr, len::Quantity, ch) =
    SpectrumBuf(T, sr, inframes(Int,len, sr))

# terminology:
# sample - a single value representing the amplitude of 1 channel at some point in time (or frequency)
# channel - a set of samples running in parallel
# frame - a collection of samples from each channel that were sampled simultaneously

# audio methods
"""
    samplerate(x)

Returns the sampling rate of `x`
"""
samplerate(buf::AbstractSampleBuf) = buf.samplerate

"""
    nchannels(x)

Returns the number of channels in the buffer or stream `x`.
"""
nchannels(buf::AbstractSampleBuf{T, 2}) where {T} = size(buf.data, 2)
nchannels(buf::AbstractSampleBuf{T, 1}) where {T} = 1

"""
    nframes(x)

Returns the length of `x` in frames (time instants). Each frame may have
multiple channels.
"""
nframes(buf::AbstractSampleBuf) = size(buf.data, 1)

"""
    samplerate!(buf, 44100)

Set the samplerate of `buf` without modifying the audio. In effect this speeds
up or slows down the signal, assuming it's played back at the original
samplerate.
"""
function samplerate!(buf::AbstractSampleBuf, sr)
    buf.samplerate = sr

    buf
end

# define audio methods on raw buffers as well
nframes(arr::AbstractArray) = size(arr, 1)
nchannels(arr::AbstractArray) = size(arr, 2)

# it's important to define Base.similar so that range-indexing returns the
# right type, instead of just a bare array
Base.similar(buf::SampleBuf, ::Type{T}, dims::Dims) where {T} = SampleBuf(Array{T}(undef, dims), samplerate(buf))
Base.similar(buf::SpectrumBuf, ::Type{T}, dims::Dims) where {T} = SpectrumBuf(Array{T}(undef, dims), samplerate(buf))

"""
    domain(buf)

Returns the range of time (for `SampleBuf`s) or frequency (for `SpectrumBuf`s)
corresponding to each sample of `buf`.
"""
domain(buf::AbstractSampleBuf) = range(0.0, stop=(nframes(buf)-1)/samplerate(buf), length=nframes(buf))

# inherit the samplerate from the first argument. TODO: we should probably
# throw an error if there are multiple SampleBufs with different sample rates.
for B in (SampleBuf, SpectrumBuf)
    @eval Base.BroadcastStyle(::Type{<:$B}) = ArrayStyle{$B}()
    @eval function Base.similar(bc::Broadcasted{ArrayStyle{$B}}, ::Type{T}) where T
        srs = find_srs(bc)
        @assert length(srs) >= 1
        if any(!=(first(srs)), srs)
            throw(ArgumentError("All samplerates in a broadcasting expression must match"))
        end
        $B(similar(Array{T}, axes(bc)), first(srs))
    end
end

# to see more about customizing broadcasting see this:
# https://docs.julialang.org/en/latest/manual/interfaces/#Selecting-an-appropriate-output-array-1

find_srs(bc::Broadcasted) = find_srs(bc.args)
find_srs(args::Tuple) = (find_srs(first(args))...,
                         find_srs(Base.tail(args))...)
find_srs(buf::AbstractSampleBuf) = (samplerate(buf),)
find_srs(::Tuple{}) = ()
find_srs(::Any) = ()

typename(::SampleBuf{T, N}) where {T, N} = "SampleBuf{$T, $N}"
unitname(::SampleBuf) = "s"
srname(::SampleBuf) = "Hz"
typename(::SpectrumBuf{T, N}) where {T, N} = "SpectrumBuf{$T, $N}"
unitname(::SpectrumBuf) = "Hz"
srname(::SpectrumBuf) = "s"

# from @mbauman's Sparklines.jl package
const ticks = ['▁','▂','▃','▄','▅','▆','▇','█']

# 3-arg version (with explicit mimetype) is needed because we subtype AbstractArray,
# and there's a 3-arg version defined in show.jl
function show(io::IO, ::MIME"text/plain", buf::AbstractSampleBuf)
    println(io, "$(nframes(buf))-frame, $(nchannels(buf))-channel $(typename(buf))")
    len = nframes(buf) / samplerate(buf)
    ustring = unitname(buf)
    srstring = srname(buf)
    print(io, "$(len)$ustring sampled at $(samplerate(buf))$srstring")
    #nframes(buf) > 0 # && showchannels(io, buf)
end

function showchannels(io::IO, buf::AbstractSampleBuf, widthchars=80)
    # number of samples per block
    blockwidth = round(Int, nframes(buf)/widthchars, RoundUp)
    nblocks = round(Int, nframes(buf)/blockwidth, RoundUp)
    blocks = Array{Char}(undef, nblocks, nchannels(buf))
    for blk in 1:nblocks
        i = (blk-1)*blockwidth + 1
        n = min(blockwidth, nframes(buf)-i+1)
        peaks = maximum(abs.(float.(buf[(1:n) .+ i .- 1, :])), dims=1)
        # clamp to -60dB, 0dB
        peaks = clamp.(20log10.(peaks), -60.0, 0.0)
        idxs = trunc.(Int, (peaks.+60)/60 * (length(ticks)-1)) .+ 1
        blocks[blk, :] = ticks[idxs]
    end
    for ch in 1:nchannels(buf)
        println(io)
        print(io, String(blocks[:, ch]))
    end
end

"""Get a pointer to the underlying data for the buffer. Will return a Ptr{T},
where T is the element type of the buffer. This is particularly useful for
passing to C libraries to fill the buffer"""
channelptr(buf::Array, channel, frameoffset=0) =
    pointer(buf) + ((channel-1)*nframes(buf)+frameoffset) * sizeof(eltype(buf))
channelptr(buf::AbstractSampleBuf, channel, frameoffset=0) =
    channelptr(buf.data, channel, frameoffset)

"""Mix the channels of the source array into the channels of the dest array,
using coefficients from the `mix` matrix. To mix an M-channel buffer to a
N-channel buffer, `mix` should be MxN. `src` and `dest` should not share
memory."""
function mix!(dest::AbstractMatrix, src::AbstractMatrix, mix::AbstractArray)
    inchans = nchannels(src)
    outchans = nchannels(dest)
    size(mix) == (inchans, outchans) || error("Mix Matrix should be $(inchans)x$(outchans)")
    mul!(dest, src, mix)
end

function mix!(dest::AbstractVector, src::AbstractVector, mix::AbstractArray)
    mix!(reshape(dest, (length(dest), 1)), reshape(src, (length(src), 1)), mix)
    dest
end

function mix!(dest::AbstractVector, src::AbstractMatrix, mix::AbstractArray)
    mix!(reshape(dest, (length(dest), 1)), src, mix)
    dest
end

function mix!(dest::AbstractMatrix, src::AbstractVector, mix::AbstractArray)
    mix!(dest, reshape(src, (length(src), 1)), mix)
end


"""Mix the channels of the source array into the channels of the dest array,
using coefficients from the `mix` matrix. To mix an M-channel buffer to a
N-channel buffer, `mix` should be MxN. `src` and `dest` should not share
memory."""
function mix(src::AbstractArray, mix::AbstractArray)
    dest = similar(src, (nframes(src), size(mix, 2)))
    mix!(dest, src, mix)
end

"""Mix the channels of the `src` array into the mono `dest` array."""
function mono!(dest::AbstractArray, src::AbstractArray)
    mix!(dest, src, ones(nchannels(src), 1) ./ nchannels(src))
end

"""Mix the channels of the `src` array into a mono array."""
function mono(src::AbstractArray)
    dest = similar(src, (nframes(src), 1))
    mono!(dest, src)
end


# the index types that Base knows how to handle. Separate out those that index
# multiple results
const BuiltinMultiIdx = Union{Colon,
                        Vector{Int},
                        Vector{Bool},
                        AbstractRange{Int}}
const BuiltinIdx = Union{Int, BuiltinMultiIdx}
# the index types that will need conversion to built-in index types. Each of
# these needs a `toindex` method defined for it
const ConvertIdx{T1 <: Quantity, T2 <: Int} = Union{T1,
                                                # Vector{T1}, # not supporting vectors of Quantities (yet?)
                                                # Range{T1}, # not supporting ranges (yet?)
                                                ClosedInterval{T2},
                                                ClosedInterval{T1}}

"""
    toindex(buf::SampleBuf, I)

Convert the given index value to one that Base knows how to use natively for
indexing
"""
function toindex end

toindex(buf::SampleBuf, t::Number) = t
toindex(buf::SampleBuf, t::FrameQuant) = inframes(Int, t) + 1
toindex(buf::SampleBuf, t::Unitful.Time) = inframes(Int, t, samplerate(buf)) + 1
toindex(buf::SampleBuf, t::Unitful.AbstractQuantity) = throw(Unitful.DimensionError(t, s))
toindex(buf::SpectrumBuf, f::Number) = f
toindex(buf::SpectrumBuf, f::FrameQuant) = inframes(Int, f) + 1
toindex(buf::SpectrumBuf, f::Unitful.Frequency) = inframes(Int, f, samplerate(buf)) + 1
toindex(buf::SpectrumBuf, f::Unitful.AbstractQuantity) = throw(Unitful.DimensionError(f, Hz))

# indexing by vectors of Quantities not yet supported
toindex(buf::AbstractSampleBuf, I::ClosedInterval{Int}) =
    toindex(buf, minimum(I)*frames):toindex(buf, maximum(I)*frames)
toindex(buf::AbstractSampleBuf, I::ClosedInterval{T}) where {T <: Quantity} =
    toindex(buf, minimum(I)):toindex(buf, maximum(I))

# AbstractArray interface methods
Base.size(buf::AbstractSampleBuf) = size(buf.data)
Base.IndexStyle(::Type{T}) where {T <: AbstractSampleBuf} = Base.IndexLinear()
# this is the fundamental indexing operation needed for the AbstractArray interface
Base.getindex(buf::AbstractSampleBuf, i::Int) = buf.data[i];

Base.getindex(buf::AbstractSampleBuf, I::ConvertIdx) = buf[toindex(buf, I)]
Base.getindex(buf::AbstractSampleBuf, I1::ConvertIdx, I2::BuiltinIdx) =
    buf[toindex(buf, I1), I2]
# In Julia 0.5 scalar indices are now dropped, so by default indexing
# buf[5, 1:2] gives you a 2-frame single-channel buffer instead of a 1-frame
# two-channel buffer. The following getindex method defeats the index dropping
Base.getindex(buf::AbstractSampleBuf, I1::Int, I2::BuiltinMultiIdx) = buf[I1:I1, I2]

function Base.setindex!(buf::AbstractSampleBuf, val, i::Int)
    buf.data[i] = val
end

# equality
import Base.==
==(buf1::AbstractSampleBuf, buf2::AbstractSampleBuf) =
    samplerate(buf1) == samplerate(buf2) &&
    buf1.data == buf2.data

FFTW.fft(buf::SampleBuf) = SpectrumBuf(FFTW.fft(buf.data), nframes(buf)/samplerate(buf))
FFTW.ifft(buf::SpectrumBuf) = SampleBuf(FFTW.ifft(buf.data), nframes(buf)/samplerate(buf))

# does a per-channel convolution on SampleBufs
for buftype in (:SampleBuf, :SpectrumBuf)
    @eval function DSP.conv(b1::$buftype{T1, 1}, b2::$buftype{T2, 1}) where {T1, T2}
        if !isapprox(samplerate(b1), samplerate(b2))
            error("Resampling convolution not yet supported")
        end
        $buftype(conv(b1.data, b2.data), samplerate(b1))
    end

    @eval function DSP.conv(b1::$buftype{T1, N1}, b2::$buftype{T2, N2}) where {T1, T2, N1, N2}
        if !isapprox(samplerate(b1), samplerate(b2))
            error("Resampling convolution not yet supported")
        end
        if nchannels(b1) != nchannels(b2)
            error("Broadcasting convolution not yet supported")
        end
        out = $buftype(promote_type(T1, T2), samplerate(b1), nframes(b1)+nframes(b2)-1, nchannels(b1))
        for ch in 1:nchannels(b1)
            out[:, ch] = conv(b1.data[:, ch], b2.data[:, ch])
        end

        out
    end

    @eval function DSP.conv(b1::$buftype{T1, 1}, b2::StridedVector{T2}) where {T1, T2}
        $buftype(conv(b1.data, b2), samplerate(b1))
    end

    @eval DSP.conv(b1::StridedVector{T1}, b2::$buftype{T2, 1}) where {T1, T2} = conv(b2, b1)

    @eval function DSP.conv(b1::$buftype{T1, 2}, b2::StridedMatrix{T2}) where {T1, T2}
        if nchannels(b1) != nchannels(b2)
            error("Broadcasting convolution not yet supported")
        end
        out = $buftype(promote_type(T1, T2), samplerate(b1), nframes(b1)+nframes(b2)-1, nchannels(b1))
        for ch in 1:nchannels(b1)
            out[:, ch] = conv(b1.data[:, ch], b2[:, ch])
        end

        out
    end

    @eval DSP.conv(b1::StridedMatrix{T1}, b2::$buftype{T2, 2}) where {T1, T2} = conv(b2, b1)
end