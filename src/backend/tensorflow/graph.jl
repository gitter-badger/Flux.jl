using Base: @get!
using DataFlow: Constant, constant, Context, interpret, Split,
  interpv, ituple, ilambda, iconst, iline, stack, mux
using Flux: imap
using TensorFlow: RawTensor

# TODO: implement Julia's type promotion rules

node(x::Tuple) = map(node, x)
node(x::Tensor) = x
node(x::Variable) = x
node(x::Number) = TensorFlow.constant(Float32(x))

graph(::typeof(tuple), args...) = (args...,)
graph(s::Split, t::Tuple) = t[s.n]
graph(::typeof(softmax), x) = nn.softmax(x)
graph(::typeof(relu), x) = nn.relu(x)
graph(::typeof(σ), x) = nn.sigmoid(x)
graph(::typeof(hcat), xs...) = concat(1, xs)
graph(::typeof(seq), xs, n) = TensorFlow.unpack(xs, num = n, axis = 1)

for op in (tanh, *, .*, +, -)
  @eval graph(::typeof($op), args...) = $op(node(args)...)
end

graph(::typeof(.-), args...) = -(node(args)...)

# reshape hack due to https://github.com/malmaud/TensorFlow.jl/issues/79
batchsize(x::Tensor) = reduce_sum(slice(TensorFlow.shape(x), [0], [1]))
graph(::typeof(flatten), x) = reshape(x, pack([batchsize(x), Int32(-1)]))
graph(r::Reshape, x) = reshape(x, pack([batchsize(x), map(Int32, r.dims)...]))

graph(::Input, x) = x

graph(p::MaxPool, x) =
  nn.max_pool(x, [1, p.size..., 1], [1, p.stride..., 1], "VALID")

graph(op::Op, xs...) = op.f(xs...)

function graph(ctx::Context, model, args...)
  node = graph(model, interpv(ctx, args)...)
  isa(node, Tensor) && (ctx[:stacks][node.op.name] = stack(ctx))
  return node
end

interp(ctx, c::Conv2D, x) =
  nn.conv2d(interpv(ctx, x), interp(ctx, Constant(c.filter)), [1,c.stride...,1], "VALID")

interp{T<:AArray}(ctx, p::Constant{Flux.Param{T}}) =
  haskey(ctx[:params], p.value) ?
     ctx[:params][p.value] :
    (ctx[:params][p.value] = Variable(p.value.x))

interp(ctx, p::Constant) = p.value

function interp(ctx, model, args...)
  g = Flux.graph(model)
  g == nothing && return graph(ctx, model, args...)
  DataFlow.iscyclic(g) && error("This model has a cycle; try unrolling it first.")
  interpret(ctx, g, interpv(ctx, args)...)
end

function tograph(model, args...)
  ctx = Context(mux(iline, ilambda, ituple, imap, interp),
                params = ObjectIdDict(), stacks = Dict())
  out = interp(ctx, model, map(constant, args)...)
  return ctx[:params], ctx[:stacks], out
end

TensorFlow.Tensor(m::Flux.Model, args...) = tograph(m, args...)[2]

RawTensor(data::Union{Batch,Seq}) = RawTensor(rawbatch(data))
