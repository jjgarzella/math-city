# CPU-only warmup. Never allocate GPU buffers or bake editable city packages.
using TOML
project = TOML.parsefile(Base.active_project())
deps = get(project, "deps", Dict())
if haskey(deps, "Oscar")
    using Oscar
    R, (x, y, z) = Oscar.polynomial_ring(Oscar.QQ, ["x", "y", "z"])
    f = x^2 + 2*x*y + 3*x*z + 4*y^2 + 5*y*z + 6*z^2
    @assert f(1, 2, 3) == 114
    @assert (x+y)^2 == x^2 + 2*x*y + y^2
elseif haskey(deps, "AbstractAlgebra")
    using AbstractAlgebra
    R, x = AbstractAlgebra.polynomial_ring(AbstractAlgebra.QQ, "x")
    @assert (x+1)^2 == x^2+2*x+1
end
if haskey(deps, "Combinatorics")
    using Combinatorics
    @assert length(collect(Combinatorics.combinations(1:5, 2))) == 10
end
if haskey(deps, "CSV") && haskey(deps, "DataFrames")
    using CSV, DataFrames
    frame = CSV.read(IOBuffer("x,y\n1,2\n3,4\n"), DataFrames.DataFrame)
    @assert sum(frame.x) == 4
end
if haskey(deps, "CUDA")
    using CUDA
    # Current deployment is macOS Apple Silicon. This checks CPU-only import
    # and driver discovery, never a GPU allocation or kernel launch.
    Sys.isapple() && @assert !CUDA.functional()
end
