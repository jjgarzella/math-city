# Run with the installed Julia 1.13 binary and repaired service project/depot.
# Does not start a server or gate.
using Kaimon

include(joinpath(@__DIR__, "kaimon-managed-bootstrap.jl"))

syntax_tree(x) = x isa Expr ? Expr(x.head,
    (syntax_tree(a) for a in x.args if !(a isa LineNumberNode))...) : x

for restart in (false, true)
    # Exercise quoting as well as launch order: the path must stay one literal.
    project = "/tmp/kaimon check/quote\"/dollar\$/project"
    script = Kaimon._build_session_script(project; name="check", allow_restart=restart)
    statements = filter(x -> !(x isa LineNumberNode), Meta.parseall(script).args)
    @assert length(statements) == 6
    @assert statements[1] == :(cd($project))
    @assert statements[2] == :(import Pkg)
    @assert syntax_tree(statements[3]) == syntax_tree(Meta.parse("try; using Revise; catch; end"))
    @assert statements[4] == :(using KaimonGate)
    @assert statements[5] == :(Pkg.instantiate(; io=devnull))
    @assert syntax_tree(statements[6]) == syntax_tree(Meta.parse("@async KaimonGate.serve(force=true, allow_mirror=true, allow_restart=$restart, spawned_by=\"agent\")"))
end
println("BOOTSTRAP_GENERATION_PASS")
