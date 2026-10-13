# Local, reversible Kaimon 2.9.0 bootstrap repair (mc-1xkm.13).
# Load the runtime's Pkg before Revise/gate dependencies can select versions
# from a target manifest written by another Julia release. Keep instantiation
# and gate attachment in their original positions, and leave package sources
# and manifests intact. Refuse an unfamiliar upstream generator on upgrade.
let
    Base.pkgversion(Kaimon) == v"2.9.0" ||
        error("Revalidate the mc-1xkm.13 bootstrap repair after upgrading Kaimon")
    probe = "/kaimon-bootstrap-probe"
    expected = """
    cd($(repr(probe)))
    try; using Revise; catch; end
    using KaimonGate
    import Pkg; Pkg.instantiate(; io=devnull)
    @async KaimonGate.serve(force=true, allow_mirror=true, allow_restart=false, spawned_by="agent")
    """
    Kaimon._build_session_script(probe; name="probe", allow_restart=false) == expected ||
        error("Kaimon managed bootstrap changed; revalidate the mc-1xkm.13 repair")
end

@eval Kaimon function _build_session_script(project_path::String;
                                           name::String = "",
                                           allow_restart::Bool = true)
    return """
    cd($(repr(project_path)))
    import Pkg
    try; using Revise; catch; end
    using KaimonGate
    Pkg.instantiate(; io=devnull)
    @async KaimonGate.serve(force=true, allow_mirror=true, allow_restart=$(allow_restart), spawned_by="agent")
    """
end
