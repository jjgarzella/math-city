# Imports must also appear explicitly in the native ex() expression, so the
# gate suspends stream capture during package precompilation if needed.
using DeRham, Oscar, CUDA, SHA
if @isdefined(city_canary_expected)
    @assert Base.active_project() == city_canary_expected["project"]
    @assert bytes2hex(SHA.sha256(read(Base.active_project()))) == city_canary_expected["project_sha256"]
    @assert bytes2hex(SHA.sha256(read(city_canary_expected["manifest"]))) == city_canary_expected["manifest_sha256"]
end
R, (x,y,z) = Oscar.polynomial_ring(Oscar.QQ, ["x","y","z"])
f = x^2 + 2*x*y + 3*x*z + 4*y^2 + 5*y*z + 6*z^2
city_coefficients = DeRham.polynomial_to_vector(f, 3)
@assert city_coefficients == [6,5,4,3,2,1]
@assert DeRham.vector_to_polynomial(city_coefficients, 2, 2, R) == f
@assert f(1,2,3) == 114
@assert !CUDA.functional()  # current macOS Apple Silicon, no GPU claim
city_names = Set(["DeRham","GPUFiniteFieldMatrices","Oscar","Nemo","AbstractAlgebra",
             "CUDA","GPUCompiler","LLVM","KernelAbstractions","CSV","DataFrames",
             "Preferences","JLLWrappers","ZMQ","KaimonGate"])
city_provenance = Dict(id.name=>Dict("uuid"=>string(id.uuid),
    "version"=>string(Base.pkgversion(mod)), "path"=>something(pathof(mod),""))
    for (id,mod) in Base.loaded_modules if id.name in city_names)
Dict("version"=>string(VERSION), "project"=>Base.active_project(),
     "image"=>unsafe_string(Base.JLOptions().image_file), "pid"=>getpid(),
     "status"=>get(ENV,"KAIMON_CITY_SYSIMAGE","explicit image recipe"),
     "coefficients"=>string(city_coefficients), "cuda_functional"=>CUDA.functional(),
     "provenance"=>city_provenance, "revise_loaded"=>any(id.name=="Revise" for id in keys(Base.loaded_modules)))
