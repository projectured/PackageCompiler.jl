# Reactive materialization: rebuild an application bundle after a source edit
# for about the cost of the edit's cone, on a Julia whose runtime supports
# JULIA_REACTIVE_REUSE (the `reactive-compiler` branch).
#
# The system is described in the `julia-reactive` checkout:
# `contrib/reactive-compiler/doc/architecture.md` says what is built and why,
# and `contrib/reactive-compiler/plan/done/reactive-materialization.md`
# holds the chronological record and the measurements.
# The harness — the ledger, the classifier, the apply, the trace precompile,
# the save and the server — is the stdlib `ReactiveCompiler` of that Julia,
# in every image it builds; this file is a client of its protocol.

export materialize_app, refresh_trace, stop_server, server_status, store_status,
       tracked_sources, watch_app, print_store_status

# The harness of the reactive compiler: the stdlib `ReactiveCompiler` of the
# reactive Julia, in its system image, found by its uuid so that no
# environment has to name it; a plain build on another Julia never asks.
const REACTIVE_COMPILER_UUID = Base.UUID("1dda119b-71a3-45fb-bd14-d17b1eb16859")
_reactive_compiler() = Base.require(Base.PkgId(REACTIVE_COMPILER_UUID, "ReactiveCompiler"))
_reactive_compiler_load() = "const ReactiveCompiler = Base.require(Base.PkgId(Base.UUID(\"1dda119b-71a3-45fb-bd14-d17b1eb16859\"), \"ReactiveCompiler\"))"

const REACTIVE_STORE_DIR = "reactive-store"
const REACTIVE_STORE_FILE = "store.toml"
const REACTIVE_TRACE_FILE = "trace.jl"

_reactive_store_dir(app_dir) = joinpath(abspath(app_dir), REACTIVE_STORE_DIR)
_reactive_snapshot_dir(store, id) = joinpath(store, "s$id")
_reactive_sysimage(app_dir) = joinpath(abspath(app_dir), "lib", "julia", "sys." * Libdl.dlext)
_reactive_trace(store) = joinpath(store, REACTIVE_TRACE_FILE)

"""
    materialize_app(package_dir, app_dir; tracked, workload = nothing, kwargs...)

Build the application the way `create_app` does, but keep a store of the
emitted text objects, of the tracked sources and of the trace inside the
bundle — and when the store already holds a snapshot, rebuild only the delta
of the edit.

- With no store: trace the workload in a throwaway process, run
  `create_app(package_dir, app_dir; kwargs...)` with the statements of the
  trace, and found the store as snapshot 1 with the trace as
  `reactive-store/trace.jl`.
- With a store: spawn one child that boots from the bundle's own system
  image with `JULIA_REACTIVE_REUSE=1`, applies the changes of the tracked
  files, precompiles the statements of the trace, and emits the delta; then
  link the text objects of every snapshot in front of the delta into a fresh
  system image. Only `lib/julia/sys.<ext>` of the bundle changes.

Two options shape the rebuild. `trim = :on` (`JULIA_REACTIVE_TRIM`) writes
a trimmed image beside the untrimmed one, into `<app_dir>/trimmed`, and
refuses an edit that makes a call site dynamic. `image = :pages`
(`JULIA_REACTIVE_IMAGE_WRITE`) makes the rebuild write only the pages of
the image that the process wrote and append the new objects; the clean
pages come from the file of the base image. The founding writes whole.

`tracked` is a vector of `file => module` pairs: a source file to watch, and
the dotted path of the module whose `include` loads it — the empty path for
the root file of the package, whose top level is the `module` block itself.
`workload` is a file that calls the program: the founding traces it, and
`refresh_trace` traces it again from the current image. No build executes
it. The trace is the set of roots of the image: a statement that an edit
invalidated is inferred again by the rebuild child, and a specialization
that no statement names is compiled by the binary at run time. On a rebuild
`tracked` names the files to track now — a file that joined the program is
added, a removed one leaves — and without it the list of the previous
snapshot stays; the workload and the keyword arguments of `create_app` are
read from the store (`cpu_target`, `sysimage_build_args` are recorded; the
bundle steps do not run again). `precompile_execution_file` is refused: the
workload is the one script; `precompile_statements_file` joins the trace.

`keep_object_archive` names a file where the founding leaves a copy of the
object archive of its image, for a caller that links the image into a program
of its own: a rebuild then writes only the overlay and its chain, and the
program applies them at its start.

`track_dependencies = true` adds the sources of every path package of the
Manifest of `package_dir` to `tracked`, on the founding and on each rebuild:
the packages that a developer edits beside the application. A rebuild then
applies an edit of such a package as it applies an edit of the application,
and a file that joined one of them is tracked from that rebuild on.

Both builds write the reactive image format (`reactive_image = true`, version
3): one function table in id order, one section per function, and a link with
`--gc-sections` that drops every function the table does not name. A rebuild
keeps the ids of the functions it reuses and drops the rest, so the image does
not grow with the edits. The format holds one CPU target, and a rebuild from
an image of the stock format is refused.

A rebuild classifies every changed top-level expression with an id of the
change catalog of the plan (see the stdlib `ReactiveCompiler`), and refuses the ones
that only a founding build applies: a module option, a new dependency, a
type that an untracked file names, a changed module header, an `include` of
an untracked file. A refusal raises with the reasons, and leaves the store
and the bundle as they were.

This needs the reactive Julia: a rebuild on a stock Julia refuses.
"""
function materialize_app(package_dir::String, app_dir::String;
                         tracked::Vector{Pair{String, String}} = Pair{String, String}[],
                         workload::Union{Nothing, String} = nothing,
                         incremental::Bool = true,
                         precompile_statements_file::Union{String, Vector{String}} = String[],
                         cpu_target::String = default_app_cpu_target(),
                         sysimage_build_args::Cmd = ``,
                         server::Bool = get(ENV, "JULIA_REACTIVE_SERVER", "") == "1",
                         trim::Symbol = Symbol(get(ENV, "JULIA_REACTIVE_TRIM", "off")),
                         image::Symbol = Symbol(get(ENV, "JULIA_REACTIVE_IMAGE_WRITE", "whole")),
                         founding::Bool = get(ENV, "JULIA_REACTIVE_FOUNDING", "") == "1",
                         compact::Tuple{Int, Float64} = _reactive_compact_env(),
                         delta_opt::Int = parse(Int, get(ENV, "JULIA_REACTIVE_DELTA_OPT", "-1")),
                         track_dependencies::Bool = false,
                         kwargs...)
    trim in (:off, :on, :once) || error("materialize_app: `trim` is :off, :on or :once, not :", trim)
    store = _reactive_store_dir(app_dir)
    if isfile(joinpath(store, REACTIVE_STORE_FILE)) && isfile(_reactive_sysimage(app_dir))
        track_dependencies &&
            (tracked = _merge_tracked(isempty(tracked) ? tracked_sources(package_dir) : tracked,
                                      _dependency_sources(package_dir)))
        reason = _materialize_rebuild(app_dir, store, tracked, founding, compact, server, trim, image, delta_opt)
        reason === nothing && return app_dir
        config = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))["config"]
        isempty(tracked) && (tracked = [String(e["file"]) => String(e["root"]) for e in config["tracked"]])
        workload === nothing && !isempty(get(config, "workload", "")) && (workload = String(config["workload"]))
        @info "materialize_app: the store founds again" reason
        stop_server(app_dir)
    end
    # The tracked files of a founding: the includes of the package's root
    # file, unless the caller names them.
    isempty(tracked) && (tracked = tracked_sources(package_dir))
    incremental ||
        error("materialize_app: the trace runs from the image of this process; `incremental = false` is not supported")
    haskey(kwargs, :precompile_execution_file) &&
        error("materialize_app: pass the script through `workload`; its trace is the store's trace.jl")
    # The founding builds into a directory beside the app and swaps it in at
    # the end: a build killed on the way leaves the old app and its store
    # as they were, and a founding again keeps the old store until the new
    # one is whole. The staging directory of a killed founding goes first.
    app_dir = abspath(app_dir)
    staging = app_dir * ".founding"
    rm(staging; recursive = true, force = true)
    # A dynamic call: the compile of a rebuild does not infer the founding,
    # whose `create_app` is large, for the keywords of each caller.
    Base.invokelatest(_materialize_full, package_dir, staging, _reactive_store_dir(staging); trim,
                      tracked, track_dependencies, workload,
                      precompile_statements_file = vcat(precompile_statements_file),
                      cpu_target, sysimage_build_args, kwargs...)
    old = app_dir * ".old"
    rm(old; recursive = true, force = true)
    ispath(app_dir) && mv(app_dir, old)
    mv(staging, app_dir)
    rm(old; recursive = true, force = true)
    return app_dir
end

# The rebuild of a store, or the reason why it founds again. Its arguments
# are concrete, so that its code is in the package image whatever keywords
# the caller of `materialize_app` passes.
function _materialize_rebuild(app_dir::String, store::String, tracked::Vector{Pair{String, String}},
                              founding::Bool, compact::Tuple{Int, Float64}, server::Bool, trim::Symbol,
                              image::Symbol, delta_opt::Int)
    image in (:whole, :pages, :overlay) || error("materialize_app: `image` is :whole, :pages or :overlay, not :", image)
    -1 <= delta_opt <= 3 || error("materialize_app: `delta_opt` is 0 to 3, or -1 for the build's level, not ", delta_opt)
    # The garbage of the log: a rebuild appends to the image and never
    # removes; past `compact` saves or growth, or on `founding`, the store
    # founds again from the tracked files and the workload it recorded, and
    # the chain starts over.
    reason = _reactive_compact_reason(app_dir, store, founding, compact, image)
    reason === nothing || return reason
    _materialize_delta(app_dir, store, tracked; server, trim, image, delta_opt)
    return nothing
end

function _materialize_full(package_dir, app_dir, store; trim::Symbol = :off,
                           tracked, track_dependencies::Bool = false, workload,
                           precompile_statements_file, cpu_target, sysimage_build_args,
                           keep_object_archive::Union{Nothing, String} = nothing, kwargs...)
    package_dir = abspath(package_dir)
    for (file, _) in tracked
        isfile(file) || error("materialize_app: no tracked file $(abspath(file))")
    end
    workload === nothing || isfile(workload) ||
        error("materialize_app: no workload file $workload")
    for file in precompile_statements_file
        isfile(file) || error("materialize_app: no statements file $file")
    end
    ctx = create_pkg_context(package_dir)
    package_name = ctx.env.pkg.name
    executables = get(kwargs, :executables, nothing)
    executables === nothing && (executables = [package_name => "julia_main"])
    # The trace: the workload in a throwaway process, from the image of this
    # process and the source-only cache, so that every specialization it
    # executes is compiled there and recorded. The entries of the executables
    # are roots too: `create_app` precompiles them in the founding, and the
    # rebuild must keep them valid.
    Pkg.instantiate(ctx, verbose = true, allow_autoprecomp = false)
    # The Manifest exists from here on, so the path packages are known.
    track_dependencies && (tracked = _merge_tracked(tracked, _dependency_sources(package_dir)))
    files = [abspath(file) for (file, _) in tracked]
    roots = [root for (_, root) in tracked]
    base_sysimage = unsafe_string(Base.JLOptions().image_file)
    statements = String["precompile(Tuple{typeof($package_name.$julia_main)})"
                        for (_, julia_main) in executables]
    if workload !== nothing
        ensurecompiled(package_dir, [package_name], base_sysimage)
        tracefile = run_precompilation_script(package_dir, base_sysimage, abspath(workload), mktempdir())
        append!(statements, _reactive_statements(tracefile))
    end
    for file in precompile_statements_file
        append!(statements, _reactive_statements(file))
    end
    statements = _reactive_roots(statements)
    # `create_app` clears `app_dir`, so the archive and the trace land outside
    # it and the store is founded after the build.
    trace = tempname() * "-trace.jl"
    write(trace, join(statements, '\n') * "\n")
    archive = tempname() * "-reactive.a"
    # The founding precompiles the trace through the harness too, so that its
    # image holds the harness's cache of the resolved statements: a server
    # that starts from the founding image precompiles the trace by lookups,
    # with no parse and no evaluation of each statement.
    harness_script = tempname() * "-founding.jl"
    write(harness_script, "Base.require(Base.PkgId(Base.UUID($(repr(string(REACTIVE_COMPILER_UUID)))), \"ReactiveCompiler\")).rc_precompile_trace($(repr(trace)))\n")
    # Incremental: the app image grows from the image of this process, the
    # one the trace ran from. The image is written in the reactive format: a
    # rebuild reuses its functions by id and by name, and the link drops the
    # functions that lost their id.
    # The founding writes whole, whatever the environment of a gate says.
    create_app(package_dir, app_dir;
               incremental = true, cpu_target,
               sysimage_build_args = Cmd(vcat(String.(sysimage_build_args.exec), ["--reactive-image=whole"])),
               keep_object_archive = archive,
               precompile_statements_file = trace, script = harness_script,
               reactive_image = true, reactive = false, kwargs...)
    rm(harness_script)
    snapshot = _reactive_snapshot_dir(store, 1)
    mkpath(snapshot)
    _reactive_extract_text(archive, snapshot)
    # A caller that links the founding image into a program of its own keeps
    # the archive of the founding.
    if keep_object_archive !== nothing
        mkpath(dirname(abspath(keep_object_archive)))
        cp(archive, keep_object_archive; force = true)
    end
    rm(archive)
    mv(trace, _reactive_trace(store); force = true)
    _reactive_copy_sources(files, roots, snapshot)
    _reactive_write_reads(files, snapshot)
    config = Dict{String, Any}(
        "package_dir" => package_dir,
        "cpu_target" => cpu_target,
        "sysimage_build_args" => collect(sysimage_build_args.exec),
        "tracked" => [Dict{String, Any}("file" => file, "root" => root)
                      for (file, root) in zip(files, roots)],
        "workload" => workload === nothing ? "" : abspath(workload),
        "executables" => [Any[String(name), String(main)] for (name, main) in executables],
        "founding_size" => filesize(_reactive_sysimage(app_dir)))
    _reactive_save(store, Dict{String, Any}("config" => config,
                                            "snapshot" => Any[_reactive_entry(1)]))
    @info "materialize_app: the store is founded" store statements = length(statements)
    if trim != :off
        reason = _reactive_trim_product(app_dir, store, Any[_reactive_entry(1)], 1, 1,
                                        _reactive_sysimage(app_dir), nothing, config)
        reason === nothing || error("materialize_app: the trimmer refuses the founding (T1):\n", reason)
        _reactive_trim_commit(app_dir, config)
        @info "materialize_app: the trimmed product is founded" bundle = joinpath(app_dir, "trimmed")
    end
    return app_dir
end

"""
    refresh_trace(app_dir)

Trace the workload again from the current image of the bundle, and replace
`reactive-store/trace.jl` with the union of the old statements and the new
ones. A throwaway process boots from the image and runs the workload under
`--trace-compile`: what the image already compiles is not recorded, so the
new statements are the roots that the edits since the founding added. An
old statement that no longer precompiles from the image is dropped. Run it
after a rebuild whose edit calls new code, then rebuild once more.
"""
function refresh_trace(app_dir::String)
    store = _reactive_store_dir(app_dir)
    isfile(joinpath(store, REACTIVE_STORE_FILE)) && isfile(_reactive_sysimage(app_dir)) ||
        error("refresh_trace: no store under $app_dir")
    config = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))["config"]
    workload = config["workload"]
    isempty(workload) && error("refresh_trace: the store of $app_dir has no workload")
    isfile(workload) || error("refresh_trace: no workload file $workload")
    trace = _reactive_trace(store)
    old = isfile(trace) ? _reactive_statements(trace) : String[]
    dir = mktempdir()
    kept_file = joinpath(dir, "kept.jl")
    script = joinpath(dir, "refresh.jl")
    write(script, _reactive_refresh_script(workload, trace, kept_file))
    tracefile = run_precompilation_script(config["package_dir"], _reactive_sysimage(app_dir), script, dir)
    kept = _reactive_roots(_reactive_statements(kept_file))
    new = _reactive_statements(tracefile)
    statements = _reactive_roots(vcat(kept, new))
    write(trace, join(statements, '\n') * "\n")
    @info "refresh_trace: the trace is refreshed" statements = length(statements) kept = length(kept) dropped = length(old) - length(kept) added = length(statements) - length(kept)
    return trace
end

# The refresh process: the workload first, so that the trace records what the
# image does not compile; then the old statements, kept when they still
# precompile from this image.
function _reactive_refresh_script(workload, trace, kept_file)
    io = IOBuffer()
    println(io, "# generated by PackageCompiler.refresh_trace — the trace child")
    println(io, "include($(repr(workload)))")
    println(io, _reactive_compiler_load())
    println(io, "ReactiveCompiler.rc_keep_statements($(repr(trace)), $(repr(kept_file)))")
    return String(take!(io))
end

_reactive_statements(file) = String[line for line in eachline(file) if startswith(line, "precompile(")]

# The roots among the statements of a trace: each once, and none of `Main`.
# A workload script runs in the Main of the trace process, so its own
# functions and closures are traced there; no rebuild child can precompile
# them, and the binary never calls them.
_reactive_roots(statements) = unique!(filter(line -> !occursin(r"\bMain\.", line), statements))

# `JULIA_REACTIVE_COMPACT="saves,growth"`: found again after that many saves
# or that much growth of the image since the founding.
function _reactive_compact_env()
    value = get(ENV, "JULIA_REACTIVE_COMPACT", "50,0.25")
    parts = split(value, ',')
    length(parts) == 2 || error("materialize_app: JULIA_REACTIVE_COMPACT is `saves,growth`, not `", value, "`")
    return (parse(Int, strip(parts[1])), parse(Float64, strip(parts[2])))
end

# The growth of the image since the founding, as a fraction of the founding's
# size; the overlays of the chain count with the base.
function _reactive_growth(app_dir, config)
    founding_size = get(config, "founding_size", 0)
    founding_size > 0 || return 0.0
    sysimage = _reactive_sysimage(app_dir)
    size = filesize(sysimage)
    for name in _reactive_chain_read(app_dir)
        path = joinpath(dirname(sysimage), name)
        isfile(path) && (size += filesize(path))
    end
    return (size - founding_size) / founding_size
end

# ── the overlay chain (Stage G) ──────────────────────────────────────────
# `<image>.chain` names the overlays the loader applies to the base, one
# per line, relative to the image's directory.
_reactive_chain_file(app_dir) = _reactive_sysimage(app_dir) * ".chain"

function _reactive_chain_read(app_dir)
    chain = _reactive_chain_file(app_dir)
    isfile(chain) || return String[]
    return String[strip(l) for l in eachline(chain) if !isempty(strip(l)) && !startswith(strip(l), "#")]
end

# Link the archive of a save into the overlay `sys.<id>.<ext>` beside the base.
function _reactive_overlay_link(app_dir, archive, id)
    sysimage = _reactive_sysimage(app_dir)
    name = string("sys.", id, ".", Libdl.dlext)
    create_sysimg_from_object_file([archive], joinpath(dirname(sysimage), name);
                                   version = nothing, compat_level = "major", soname = name, gc_sections = true)
    return name
end

# Make `name` the whole chain: a writer of an overlay starts from the
# founding image, so its overlay holds every change since the founding. The
# overlays it replaces go.
function _reactive_chain_replace(app_dir, name)
    names = _reactive_chain_read(app_dir)
    write(_reactive_chain_file(app_dir), name * "\n")
    for replaced in names
        replaced == name || rm(joinpath(dirname(_reactive_sysimage(app_dir)), replaced); force = true)
    end
    return nothing
end

# The founding image under a path of its own: a hard link to the base of the
# bundle. The runtime reads the chain beside the real path of the image, and
# this path has none, so a process that loads it has the founding alone.
function _reactive_founding_image(app_dir, store)
    path = joinpath(store, "founding." * Libdl.dlext)
    rm(path; force = true)
    hardlink(_reactive_sysimage(app_dir), path)
    return path
end

# Why the store founds again, or nothing. An overlay store holds one overlay
# of every change since the founding, so its saves do not grow the image, and
# only the growth counts.
function _reactive_compact_reason(app_dir, store, founding, compact, image)
    founding && return "founding = true"
    data = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))
    saves = length(data["snapshot"]) - 1
    image != :overlay && saves >= compact[1] &&
        return "$saves saves since the founding, the bound is $(compact[1])"
    growth = _reactive_growth(app_dir, data["config"]::Dict{String, Any})
    growth >= compact[2] && return "the image grew $(round(100 * growth; digits = 1)) % since the founding, the bound is $(round(100 * compact[2]; digits = 1)) %"
    return nothing
end

function _materialize_delta(app_dir, store, tracked; server::Bool = false, trim::Symbol = :off,
                            image::Symbol = :whole, delta_opt::Int = -1)
    data = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))
    config = data["config"]::Dict{String, Any}
    snapshots = sort(Vector{Any}(data["snapshot"]); by = s -> s["id"])
    id = snapshots[end]["id"] + 1
    session = server ? _reactive_server_ensure(app_dir, store, config, snapshots, image, delta_opt) : nothing
    # The start: the snapshot whose image the writer loaded, and whose
    # sources are the old side of the edit. A server's is its last save. An
    # overlay child loads the founding image: its overlay holds every change
    # since the founding, and it is the whole chain.
    start = session !== nothing ? session["last"] : image == :overlay ? snapshots[1]["id"] : snapshots[end]["id"]
    parent = _reactive_snapshot_dir(store, start)
    snapshot = _reactive_snapshot_dir(store, id)
    mkpath(snapshot)
    sysimage = _reactive_sysimage(app_dir)
    old_files, old_roots, old_copies = _reactive_read_sources(parent)
    files = isempty(tracked) ? String[entry["file"] for entry in config["tracked"]] : String[abspath(file) for (file, _) in tracked]
    roots = isempty(tracked) ? String[entry["root"] for entry in config["tracked"]] : String[root for (_, root) in tracked]
    for file in files
        isfile(file) || error("materialize_app: no tracked file $file")
    end
    old_reads = _reactive_read_reads(joinpath(parent, "reads.txt"))
    reads = joinpath(snapshot, "reads.txt")
    refusal = joinpath(snapshot, "refusal.txt")
    trace = _reactive_trace(store)
    isfile(trace) || error("materialize_app: the store $store has no $REACTIVE_TRACE_FILE; found it again")
    script = joinpath(snapshot, "child.jl")
    trimmed_archive = joinpath(snapshot, "trimmed.a")
    write(script, _reactive_child_script(old_files, _reactive_paths(old_roots), old_copies,
                                         files, _reactive_paths(roots), old_reads, reads, refusal, trace;
                                         trim = !server && trim != :off, trimmed = trimmed_archive,
                                         overrides = _reactive_trim_overrides()))
    archive = joinpath(snapshot, "delta.a")
    next_sysimage = sysimage * ".next"
    base = session === nothing ? start : session["base"]
    # The overlay of this save (Stage G), linked beside the base; it joins
    # the chain only when the save is complete, below.
    overlay = ""
    if server
        # The server loaded the image of its base snapshot; its delta holds
        # every change since, so the link takes the texts of the base chain
        # and the delta.
        spec = joinpath(snapshot, "spec.toml")
        _reactive_write_spec(spec, old_files, old_roots, old_copies, files, roots,
                             joinpath(parent, "reads.txt"), reads, refusal, trace)
        reply = _reactive_request(session["socket"], "apply " * spec)
        if startswith(reply, "refused")
            reasons = isfile(refusal) ? read(refusal, String) : reply
            rm(snapshot; recursive = true, force = true)
            error("materialize_app: the rebuild is refused; a founding build applies the change:\n", reasons)
        end
        startswith(reply, "ok") || error("materialize_app: the server answered `", reply, "`; see ", joinpath(store, "server.log"))
        elapsed = @elapsed begin
            reply = _reactive_request(session["socket"], "save " * archive)
            startswith(reply, "ok") || error("materialize_app: the save answered `", reply, "`; see ", joinpath(store, "server.log"))
            if image == :overlay
                overlay = _reactive_overlay_link(app_dir, archive, id)
            else
                create_sysimg_from_object_file(vcat(_reactive_link_texts(store, snapshots, base), [archive]),
                                               next_sysimage; version = nothing, compat_level = "major",
                                               soname = basename(sysimage), gc_sections = true)
            end
        end
    else
    ancestors = _reactive_link_texts(store, snapshots, base)
    # The image write of the child: `pages` copies the clean pages of the
    # base it loads (Stage F); the founding above writes whole. The reuse,
    # the way of the write and the delta's level are flags of the child.
    elapsed = @elapsed begin
        try
            create_sysimage(nothing;
                            sysimage_path = next_sysimage,
                            project = config["package_dir"],
                            incremental = true,
                            base_sysimage = image == :overlay ? _reactive_founding_image(app_dir, store) : sysimage,
                            cpu_target = config["cpu_target"],
                            script,
                            sysimage_build_args = Cmd(vcat(String.(config["sysimage_build_args"]),
                                                           _reactive_flags(image, delta_opt))),
                            extra_object_files = ancestors,
                            keep_object_archive = archive,
                            reactive_image = true,
                            soname = basename(sysimage),
                            # An overlay build keeps the archive: it links below
                            link = image != :overlay,
                            # The previous image carries the Main bindings of its
                            # own build; a new import would only warn. The child
                            # resolves modules through `Base.loaded_modules`.
                            import_into_main = false)
        catch e
            e isa ProcessFailedException && isfile(refusal) || rethrow()
            reasons = read(refusal, String)
            rm(snapshot; recursive = true, force = true)
            rm(next_sysimage; force = true)
            startswith(reasons, "T1") &&
                error("materialize_app: the rebuild is refused (T1); the trimmer names the call sites:\n", reasons)
            error("materialize_app: the rebuild is refused; a founding build applies the change:\n", reasons)
        end
    end
    end
    image == :overlay && !server && (overlay = _reactive_overlay_link(app_dir, archive, id))
    _reactive_extract_text(archive, snapshot)
    if trim != :off
        reason = _reactive_trim_product(app_dir, store, snapshots, base, id, next_sysimage, session, config;
                                        prewritten = !server, overlay = image == :overlay)
        if reason !== nothing
            # The server applied the edit that the trimmer refuses: it stops,
            # and the next build starts a new one. The chain
            # and both bundles are as they were: the overlay of this save
            # is not in the chain yet.
            if session !== nothing
                _reactive_request(session["socket"], "quit"; quiet = true)
                rm(_reactive_server_session(store); force = true)
            end
            rm(snapshot; recursive = true, force = true)
            rm(next_sysimage; force = true)
            isempty(overlay) || rm(joinpath(dirname(sysimage), overlay); force = true)
            error("materialize_app: the rebuild is refused (T1); the trimmer names the call sites:\n", reason)
        end
    end
    if image == :overlay
        _reactive_chain_replace(app_dir, overlay)
    else
        mv(next_sysimage, sysimage; force = true)
    end
    trim != :off && _reactive_trim_commit(app_dir, config)
    rm(archive)
    _reactive_copy_sources(files, roots, snapshot)
    config["tracked"] = [Dict{String, Any}("file" => file, "root" => root)
                         for (file, root) in zip(files, roots)]
    entry = _reactive_entry(id)
    entry["base"] = base
    image == :overlay && (entry["overlay"] = overlay)
    push!(data["snapshot"], entry)
    if image == :overlay
        # The old side of the next edit is the founding for a new server and
        # this snapshot for the running one; the snapshots between them go.
        for earlier in snapshots[2:end]
            rm(_reactive_snapshot_dir(store, earlier["id"]); recursive = true, force = true)
        end
        data["snapshot"] = Any[snapshots[1], entry]
    end
    _reactive_save(store, data)
    if server
        # The server's state is this snapshot now.
        session["last"] = id
        open(_reactive_server_session(store), "w") do io
            TOML.print(io, session)
        end
    end
    growth = round(100 * _reactive_growth(app_dir, config); digits = 2)
    @info "materialize_app: snapshot s$id materialized" seconds = round(elapsed; digits = 1) server trim image growth_percent = growth
    return app_dir
end

# The module path of a dotted root: the empty path for the root file.
_reactive_paths(roots) = Vector{Symbol}[isempty(root) ? Symbol[] : Symbol.(split(root, '.')) for root in roots]

# The top level of the rebuild child. Everything that varies is a literal
# here; the function bodies are the stdlib's, compiled in the image.
function _reactive_child_script(old_files, old_roots, old_copies, files, roots, old_reads,
                                reads, refusal, trace; trim::Bool = false, trimmed = "", overrides = "")
    io = IOBuffer()
    println(io, "# generated by PackageCompiler.materialize_app — the rebuild child")
    println(io, _reactive_compiler_load())
    println(io, "rc_state = try")
    println(io, "    ReactiveCompiler.rc_apply_tracked($(repr(old_files)), $(repr(old_roots)), $(repr(old_copies)),")
    println(io, "                     $(repr(files)), $(repr(roots)),")
    println(io, "                     $(repr(old_reads)), $(repr(reads)), $(repr(refusal)))")
    println(io, "catch e")
    println(io, "    e isa ReactiveCompiler.RcRefusal || rethrow()")
    println(io, "    exit(3)")
    println(io, "end")
    println(io, "ReactiveCompiler.rc_precompile_trace($(repr(trace)))")
    println(io, "ReactiveCompiler.rc_report_new(rc_state)")
    # A global of Main stays in the image: the set of every method instance
    # would root the dead ones.
    println(io, "rc_state = nothing")
    if trim
        # The second output of a save (Stage E): this child loaded the base
        # image and applied the edit, so a fork of it writes the trimmed
        # archive from the same heap, before the exit path writes the
        # untrimmed one. A trim refusal writes the verifier's reason to the
        # refusal file with the id T1 and exits, and the builder rolls back.
        println(io, "let ok = false")
        println(io, "    try")
        println(io, "        ReactiveCompiler.rc_save($(repr(trimmed)); trim = true, overrides = $(repr(overrides)))")
        println(io, "        ok = isfile($(repr(trimmed)))")
        println(io, "    catch e")
        println(io, "        Base.showerror(stderr, e, catch_backtrace()); println(stderr)")
        println(io, "    end")
        println(io, "    if !ok")
        println(io, "        open($(repr(refusal)), \"w\") do io")
        println(io, "            println(io, \"T1\")")
        println(io, "            log = $(repr(trimmed)) * \".log\"")
        println(io, "            isfile(log) && for l in readlines(log)")
        println(io, "                (occursin(\"Verifier\", l) || occursin(\"Trim verify\", l) || occursin(\"TrimFailure\", l)) && println(io, l)")
        println(io, "            end")
        println(io, "        end")
        println(io, "        exit(4)")
        println(io, "    end")
        println(io, "end")
    end
    return String(take!(io))
end

# The files that a top-level expression of a tracked file can read, with the
# hash of their content, as `<hash> <path>` lines: the child compares them
# with the files of the next rebuild. The founding writes the listing the
# way the child does.
function _reactive_write_reads(files, snapshot)
    reads = Tuple{String, String}[]
    for file in files
        diff = _reactive_compiler().ReactiveSourceDiff
        for entry in diff.file_entries(read(file, String), file)
            for path in diff.read_paths(entry.expr, dirname(file))
                push!(reads, (path, string(hash(read(path, String)); base = 16)))
            end
        end
    end
    unique!(reads)
    open(joinpath(snapshot, "reads.txt"), "w") do io
        for (path, h) in reads
            println(io, h, " ", path)
        end
    end
    return nothing
end

function _reactive_read_reads(listing)
    reads = Tuple{String, String}[]
    isfile(listing) || return reads
    for line in eachline(listing)
        parts = split(line, " "; limit = 2)
        length(parts) == 2 && push!(reads, (String(parts[2]), String(parts[1])))
    end
    return reads
end

# The text objects of the archive, extracted into the snapshot; the heap and
# the tables of an old build are never linked again.
function _reactive_extract_text(archive, dir)
    members = split(read(`ar t $archive`, String))
    texts = String[String(m) for m in members if startswith(m, "text") && endswith(m, ".o")]
    isempty(texts) || run(Cmd(`ar x $(abspath(archive)) $texts`; dir))
    return nothing
end

_reactive_texts(dir) = String[joinpath(dir, name) for name in sort(readdir(dir))
                              if startswith(name, "text") && endswith(name, ".o")]

# The text objects that the image of a new snapshot links: the founding's,
# then the delta of every snapshot on the base chain of `base`, the snapshot
# whose image the writer loaded. A chain entry's base is the snapshot before
# it; the server's base is the snapshot it started from.
function _reactive_link_texts(store, snapshots, base)
    byid = Dict{Int, Any}(s["id"] => s for s in snapshots)
    founding = snapshots[1]["id"]
    chain = Int[]
    id = base
    while id != founding
        push!(chain, id)
        id = get(byid[id], "base", id - 1)
    end
    texts = _reactive_texts(_reactive_snapshot_dir(store, founding))
    for id in reverse(chain)
        append!(texts, _reactive_texts(_reactive_snapshot_dir(store, id)))
    end
    return texts
end

# ── the compiler server ──────────────────────────────────────────────────────

_reactive_server_session(store) = joinpath(store, "server.toml")

# A Unix socket path holds 107 bytes; a store path can be longer. The socket
# sits in the temp directory under a name derived from the store.
_reactive_server_socket(store) = joinpath(tempdir(), "jlrc-" * bytes2hex(sha256(store))[1:16] * ".sock")

function _reactive_sockaddr(path::String)
    length(path) < 108 || error("materialize_app: the socket path is too long: ", path)
    addr = zeros(UInt8, 110)
    addr[1] = 0x01   # AF_UNIX
    copyto!(addr, 3, codeunits(path), 1, length(path))
    return addr
end

# One request to the server: connect, one line, the reply line, close. An
# empty reply when the socket does not answer and `quiet` is set.
function _reactive_request(socket::String, line::String; quiet::Bool = false)
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), 1, 1, 0)
    fd < 0 && error("materialize_app: socket: ", Libc.strerror())
    addr = _reactive_sockaddr(socket)
    if ccall(:connect, Cint, (Cint, Ptr{UInt8}, UInt32), fd, addr, length(addr)) != 0
        reason = Libc.strerror()
        ccall(:close, Cint, (Cint,), fd)
        quiet && return ""
        error("materialize_app: cannot connect to the server socket ", socket, ": ", reason)
    end
    data = codeunits(line * "\n")
    offset = 0
    while offset < length(data)
        n = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, pointer(data, offset + 1), length(data) - offset)
        n > 0 || (ccall(:close, Cint, (Cint,), fd); error("materialize_app: write to the server: ", Libc.strerror()))
        offset += n
    end
    reply = UInt8[]
    buffer = Vector{UInt8}(undef, 4096)
    while true
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, buffer, length(buffer))
        n > 0 || break
        append!(reply, view(buffer, 1:n))
    end
    ccall(:close, Cint, (Cint,), fd)
    return String(strip(String(reply)))
end

function _reactive_write_spec(spec, old_files, old_roots, old_copies, files, roots, old_reads, reads, refusal, trace)
    open(spec, "w") do io
        TOML.print(io, Dict{String, Any}(
            "old_files" => old_files, "old_roots" => old_roots, "old_copies" => old_copies,
            "files" => files, "roots" => roots, "old_reads" => old_reads,
            "reads_out" => reads, "refusal_out" => refusal, "trace" => trace))
    end
    return nothing
end

# The flags of a rebuild child or a server: the reuse of the loaded image,
# the way the image is written, and the delta's optimization level (none
# for the build's own).
function _reactive_flags(image::Symbol, delta_opt::Int)
    flags = ["--reactive-reuse", "--reactive-image=$image"]
    delta_opt < 0 || push!(flags, "--reactive-delta-opt=$delta_opt")
    return flags
end

# The server of the store: the one that answers, else a new one from the
# image of the last snapshot. The session file names its socket, its base
# snapshot and its pid.

function _reactive_server_ensure(app_dir, store, config, snapshots, image = :whole, delta_opt::Int = -1)
    session_file = _reactive_server_session(store)
    socket = _reactive_server_socket(store)
    if isfile(session_file)
        session = TOML.parsefile(session_file)
        status = _reactive_request(session["socket"], "status"; quiet = true)
        if startswith(status, "ok")
            # The memory of the server: the code of every save and every
            # old method version stay until a restart. Past a number of
            # saves or a resident size the builder restarts it, and the new
            # server comes to the same state. A server whose last snapshot
            # is not the last of the store is behind it (a child build came
            # after): it restarts too.
            saves = parse(Int, something(match(r"saves=(\d+)", status), ["0"])[1])
            rss_kb = parse(Int, something(match(r"rss_kb=(\d+)", status), ["0"])[1])
            max_saves = parse(Int, get(ENV, "JULIA_REACTIVE_SERVER_SAVES", "200"))
            max_rss_kb = parse(Int, get(ENV, "JULIA_REACTIVE_SERVER_RSS_KB", string(16 * 1024 * 1024)))
            last = get(session, "last", session["base"])
            # An overlay server that did not start from the founding writes
            # its overlay onto others, and the chain keeps one overlay.
            same_image = get(session, "image", "whole") == string(image) &&
                         get(session, "delta_opt", -1) == delta_opt &&
                         (image != :overlay || session["base"] == snapshots[1]["id"])
            if saves < max_saves && rss_kb < max_rss_kb && last == snapshots[end]["id"] && same_image
                return session
            end
            @info "materialize_app: the server restarts" saves rss_kb last latest = snapshots[end]["id"]
            _reactive_request(session["socket"], "quit"; quiet = true)
        else
            @warn "materialize_app: the server of the store does not answer; a new one starts" session
        end
        rm(session_file; force = true)
    end
    # An overlay server starts from the founding image, and its first apply
    # takes every change since the founding: each save writes the whole
    # chain. Another server starts from the image of the last snapshot.
    base = image == :overlay ? snapshots[1]["id"] : snapshots[end]["id"]
    log = joinpath(store, "server.log")
    sysimage = image == :overlay ? _reactive_founding_image(app_dir, store) : _reactive_sysimage(app_dir)
    # The server is the runtime's: `--reactive-server` makes the process
    # serve on the socket from that image, in the output mode of a rebuild
    # child, with the stdlib `ReactiveCompiler` of the image.
    cmd = with_image_threads(`$(get_julia_cmd()) --cpu-target=$(config["cpu_target"])
        $(Cmd(String.(config["sysimage_build_args"]))) --sysimage=$sysimage
        --project=$(config["package_dir"]) --output-o=$(joinpath(store, "server.a")) --threads=1
        $(Cmd(_reactive_flags(image, delta_opt))) --reactive-server=$socket`)
    process = run(pipeline(detach(cmd); stdout = log, stderr = log); wait = false)
    deadline = time() + 300
    while time() < deadline
        ispath(socket) && startswith(_reactive_request(socket, "status"; quiet = true), "ok") && break
        process_exited(process) && error("materialize_app: the server exited at start; see ", log)
        sleep(0.5)
    end
    time() < deadline || error("materialize_app: the server did not answer within 300 s; see ", log)
    session = Dict{String, Any}("socket" => socket, "base" => base, "last" => base, "pid" => getpid(process),
                                "image" => string(image), "delta_opt" => delta_opt,
                                "started" => Libc.strftime("%Y-%m-%d %H:%M:%S", time()))
    open(session_file, "w") do io
        TOML.print(io, session)
    end
    @info "materialize_app: the server started" pid = session["pid"] base
    return session
end

# ── the trimmed product ─────────────────────────────────────────────────────

const TRIMMED_WRAPPER = joinpath(@__DIR__, "trimmed_wrapper.c")

_reactive_trimmed_dir(app_dir) = joinpath(app_dir, "trimmed")

# The patches to Base and to the stdlibs that a trimmed build needs, the
# ones `juliac` applies before its write (test/trimming of the Julia tree):
# the profile listener, `invokelatest`, `reinit_stdio` and a few `__init__`s
# become trivial. Their directory beside this Julia, or nothing.
function _reactive_trim_overrides()
    dir = normpath(joinpath(Sys.BINDIR, "..", "..", "test", "trimming"))
    isfile(joinpath(dir, "juliac-trim-base.jl")) && return dir
    @warn "materialize_app: no test/trimming beside this Julia; the trimmed product goes without the patches of juliac" dir
    return ""
end

# The script of the trim child: the preamble of the object script, the
# patches of a trimmed build, the entry points, and the tail; the heap is
# the loaded image, the trimmer prunes it from the entry points, and the
# reused code serves what they reach.
function _reactive_trim_script(package_dir)
    overrides = _reactive_trim_overrides()
    io = IOBuffer()
    println(io, "# generated by PackageCompiler.materialize_app — the trim child")
    println(io, "Base.reinit_stdio()")
    println(io, "@eval Sys BINDIR = ccall(:jl_get_julia_bindir, Any, ())::String")
    println(io, "@eval Sys STDLIB = ", repr(abspath(Sys.BINDIR, "../share/julia/stdlib", string('v', VERSION.major, '.', VERSION.minor))))
    println(io, "copy!(LOAD_PATH, [", repr(package_dir), ", \"@stdlib\"])")
    println(io, "Base.init_depot_path()")
    if !isempty(overrides)
        println(io, "include(", repr(joinpath(overrides, "juliac-trim-base.jl")), ")")
        println(io, "include(", repr(joinpath(overrides, "juliac-trim-stdlib.jl")), ")")
    end
    println(io, _reactive_compiler_load())
    println(io, "ReactiveCompiler.trim_entrypoints!()   # the entry points of the trim")
    println(io, "empty!(Base.Filesystem.TEMP_CLEANUP)")
    println(io, "empty!(Core.ARGS); empty!(Base.ARGS); empty!(LOAD_PATH); empty!(DEPOT_PATH)")
    println(io, "empty!(Base.TOML_CACHE.d); Base.TOML.reinit!(Base.TOML_CACHE.p, \"\")")
    println(io, "@eval Sys begin BINDIR = \"\"; STDLIB = \"\" end")
    return String(take!(io))
end

# The reason of a refusal: the verifier's lines of the log, else the reply.
function _reactive_trim_reason(log, reply)
    isfile(log) || return reply
    lines = filter(l -> occursin("Verifier", l) || occursin("Trim verify", l) || occursin("TrimFailure", l), readlines(log))
    return isempty(lines) ? string(reply, "\n", join(last(readlines(log), 20), "\n")) : join(lines, "\n")
end

# The trimmed product of a snapshot: the archive that a trimmed write of
# the heap gives, through the server or a child that loads `image`, linked
# with the texts of the chain into `<app_dir>/trimmed/lib/julia/sys.so.next`.
# Under `overlay` the link takes the founding's texts alone: the texts of an
# overlay were compiled against the overlay's own slot table, and the
# trimmed write compiled the functions of the overlays again (staticdata.c,
# `jl_reactive_image_ids` under trim). Answers nothing, or the reason of the
# trimmer's refusal.
function _reactive_trim_product(app_dir, store, snapshots, base, id, image, session, config;
                                prewritten = false, overlay = false)
    archive = joinpath(_reactive_snapshot_dir(store, id), "trimmed.a")
    log = archive * ".log"
    if session !== nothing
        # The server forks and writes the trimmed archive of its cumulative
        # delta since its base.
        rm(archive; force = true)
        reply = _reactive_request(session["socket"], string("trim ", archive, " ", _reactive_trim_overrides()))
        startswith(reply, "ok") || return _reactive_trim_reason(log, reply)
    elseif prewritten
        # No server, a delta: the apply child wrote the trimmed archive as
        # its second output (see `_reactive_child_script`). A refusal was
        # handled at the build; the archive of the trimmed delta is here.
        isfile(archive) || return _reactive_trim_reason(log, "the apply child wrote no $archive")
    else
        # No server, the founding: a child loads the founding image and
        # writes it trimmed. Every function is reused, so the archive is
        # thin and the founding's texts carry the code; the linker drops
        # the rest.
        rm(archive; force = true)
        script = joinpath(_reactive_snapshot_dir(store, id), "trim.jl")
        write(script, _reactive_trim_script(config["package_dir"]))
        cmd = with_image_threads(`$(get_julia_cmd()) --cpu-target=$(config["cpu_target"])
            $(Cmd(String.(config["sysimage_build_args"]))) --sysimage=$image
            --project=$(config["package_dir"]) --output-o=$archive --output-incremental=no
            --strip-ir --strip-metadata --experimental --trim=safe --threads=1
            --reactive-reuse --reactive-trim-memo=$(joinpath(store, "trim-memo.txt")) $script`)
        # The founding's pass writes the first memo of the store (see
        # `rc_save` of the server for the memo).
        ok = success(pipeline(cmd; stdout = log, stderr = log))
        ok && isfile(archive) || return _reactive_trim_reason(log, "the trim child failed; see $log")
    end
    # The chain of the base carries the reused code; the archive carries the
    # delta and the fresh function table. The untrimmed delta is never linked.
    texts = overlay ? _reactive_texts(_reactive_snapshot_dir(store, snapshots[1]["id"])) :
                      _reactive_link_texts(store, snapshots, base)
    next = joinpath(_reactive_trimmed_dir(app_dir), "lib", "julia", "sys." * Libdl.dlext * ".next")
    mkpath(dirname(next))
    create_sysimg_from_object_file(vcat(texts, [archive]), next; version = nothing, compat_level = "major",
                                   soname = "sys." * Libdl.dlext, gc_sections = true)
    rm(archive)
    # The trimmer walks the program from its C-callable entry points, and
    # the launcher of the trimmed bundle calls the exported symbol: an entry
    # point that is not `@ccallable` gives a trimmed image without the
    # program, which is refused here, not found at the first run.
    exported = Set{String}()
    for line in eachline(`nm -D --defined-only $next`)
        parts = split(line)
        length(parts) == 3 && push!(exported, String(parts[3]))
    end
    for (name, main) in get(config, "executables", Any[])
        main in exported && continue
        rm(next; force = true)
        return "the trimmed image exports no entry point `$main` for `$name`: declare it " *
               "`Base.@ccallable function $main()::Cint`, so that the trimmer walks the program from it"
    end
    return nothing
end

# The trimmed bundle: its own launchers, the libraries of the untrimmed one
# as hard links, and the trimmed image in place of the untrimmed.
function _reactive_trim_commit(app_dir, config)
    trimmed = _reactive_trimmed_dir(app_dir)
    share = joinpath(app_dir, "share")
    isdir(share) && !isdir(joinpath(trimmed, "share")) && run(`cp -al $share $(joinpath(trimmed, "share"))`)
    # The launcher of a trimmed bundle calls the exported entry point; the
    # launcher of the untrimmed bundle evaluates a string, which a trimmed
    # image can not do.
    executables = get(config, "executables", Any[Any[basename(config["package_dir"]), "julia_main"]])
    for (name, main) in executables
        exe = joinpath(trimmed, "bin", name)
        isfile(exe) || create_executable_from_sysimg(exe, TRIMMED_WRAPPER, main)
    end
    lib = joinpath(app_dir, "lib")
    for entry in readdir(lib)
        target = joinpath(trimmed, "lib", entry)
        entry == "julia" && continue
        ispath(target) || run(`cp -al $(joinpath(lib, entry)) $target`)
    end
    for entry in readdir(joinpath(lib, "julia"))
        target = joinpath(trimmed, "lib", "julia", entry)
        startswith(entry, "sys." * Libdl.dlext) && continue
        ispath(target) || run(`cp -al $(joinpath(lib, "julia", entry)) $target`)
    end
    image = joinpath(trimmed, "lib", "julia", "sys." * Libdl.dlext)
    mv(image * ".next", image; force = true)
    return nothing
end

"""
    store_status(app_dir) -> NamedTuple, or nothing

What the reactive store of `app_dir` holds: `founding_size`, `snapshots` (the
ids), `chain` (the overlays of the bundle, as `name => size`), `session` (the
server's session as a `Dict`, or `nothing`), `growth` (the fraction the image
grew since the founding), `tracked` (the files), `workload`. Nothing without
a store.
"""
function store_status(app_dir::String)
    store = _reactive_store_dir(app_dir)
    isfile(joinpath(store, REACTIVE_STORE_FILE)) || return nothing
    data = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))
    config = data["config"]
    snapshots = sort(Int[s["id"] for s in data["snapshot"]])
    lib = dirname(_reactive_sysimage(app_dir))
    chain = Pair{String, Int}[name => (isfile(joinpath(lib, name)) ? filesize(joinpath(lib, name)) : 0)
                              for name in _reactive_chain_read(app_dir)]
    session_file = _reactive_server_session(store)
    session = nothing
    if isfile(session_file)
        session = TOML.parsefile(session_file)
        session["alive"] = startswith(_reactive_request(session["socket"], "status"; quiet = true), "ok")
    end
    return (founding_size = get(config, "founding_size", 0),
            image_size = filesize(_reactive_sysimage(app_dir)),
            snapshots = snapshots, chain = chain, session = session,
            growth = _reactive_growth(app_dir, config),
            tracked = String[e["file"] for e in config["tracked"]],
            workload = get(config, "workload", ""))
end

"""
    stop_server(app_dir)

Stop the compiler server of the store of `app_dir`, if one runs.
"""
function stop_server(app_dir::String)
    store = _reactive_store_dir(app_dir)
    session_file = _reactive_server_session(store)
    isfile(session_file) || return false
    session = TOML.parsefile(session_file)
    reply = _reactive_request(session["socket"], "quit"; quiet = true)
    rm(session_file; force = true)
    rm(session["socket"]; force = true)
    return startswith(reply, "ok")
end

"""
    server_status(app_dir) -> String

The status line of the compiler server of the store of `app_dir`: the world,
the saves and the resident size; an empty string without a server.
"""
function server_status(app_dir::String)
    store = _reactive_store_dir(app_dir)
    isfile(_reactive_server_session(store)) || return ""
    session = TOML.parsefile(_reactive_server_session(store))
    return _reactive_request(session["socket"], "status"; quiet = true)
end

# The sources of a snapshot: a copy of each tracked file, and `tracked.toml`,
# the list of the tracked files with their roots. They are the old side of an
# edit that starts from the snapshot.
function _reactive_copy_sources(files, roots, snapshot)
    source = joinpath(snapshot, "source")
    mkpath(source)
    for (index, file) in enumerate(files)
        cp(file, _reactive_source_copy(snapshot, index, file); force = true)
    end
    open(joinpath(snapshot, "tracked.toml"), "w") do io
        TOML.print(io, Dict{String, Any}("tracked" => [Dict{String, Any}("file" => file, "root" => root)
                                                      for (file, root) in zip(files, roots)]))
    end
    return nothing
end

_reactive_source_copy(snapshot, index, file) = joinpath(snapshot, "source", string(index, "-", basename(file)))

# The tracked files of a snapshot, their roots, and their copies.
function _reactive_read_sources(snapshot)
    list = joinpath(snapshot, "tracked.toml")
    isfile(list) || error("materialize_app: the snapshot $snapshot has no tracked.toml; found the store again")
    tracked = TOML.parsefile(list)["tracked"]
    files = String[entry["file"] for entry in tracked]
    roots = String[entry["root"] for entry in tracked]
    copies = String[_reactive_source_copy(snapshot, index, file) for (index, file) in enumerate(files)]
    return files, roots, copies
end

_reactive_entry(id) = Dict{String, Any}(
    "id" => id,
    "created" => Libc.strftime("%Y-%m-%d %H:%M:%S", time()))

function _reactive_save(store, data)
    open(joinpath(store, REACTIVE_STORE_FILE), "w") do io
        TOML.print(io, data)
    end
    return nothing
end

# ── the tracked sources of a package ────────────────────────────────────────

"""
    tracked_sources(package_dir) -> Vector{Pair{String,String}}

The source files of the package at `package_dir`, each with the dotted name
of the module whose `include` loads it — the `tracked` list that
`materialize_app` takes, and the default of a founding.

Read from the package's root file: every `include` at the top level of a
module is a tracked file, evaluated in that module, and a `module` block
names a deeper module for what it includes. The walk follows the included
files too. The path of an `include` is a string literal, or a path that the
walk computes without running the package: `@__DIR__`, `@__FILE__`, a
string, and `joinpath`, `normpath`, `abspath` and `dirname` of those, or
the name of a `const` of the same module that holds such a path.

The root file comes first, with the empty module path: its top level is the
`module Pkg … end` block itself, so an `include` or a `using` that joins the
module body is an edit of a tracked file, and the rebuild applies it or
refuses it with a reason. An `include` of another path, and one inside a
function, are not tracked: the walk names them and tracks nothing for them.

With `dependencies = true` the list also holds the sources of every path
package of the Manifest of `package_dir`, each in the modules of its own
package. A file that two modules include is an error: a rebuild could apply
its edit to one of them only.
"""
function tracked_sources(package_dir::AbstractString; dependencies::Bool = false)
    dependencies && return _merge_tracked(tracked_sources(package_dir), _dependency_sources(package_dir))
    project = joinpath(package_dir, "Project.toml")
    isfile(project) || error("tracked_sources: no Project.toml under $package_dir")
    name = get(TOML.parsefile(project), "name", nothing)
    name isa String || error("tracked_sources: the project under $package_dir has no name")
    root = joinpath(package_dir, "src", name * ".jl")
    isfile(root) || error("tracked_sources: no root file $root")
    tracked = Pair{String,String}[root => ""]
    _walk_includes(_parse_file(root), root, "", tracked)
    return tracked
end

_parse_file(file) = Meta.parseall(read(file, String); filename = file)

# The blocks whose `include` runs when the module loads. An `include` anywhere
# else — a function body, a macro — runs later or never, and is not tracked.
const _TOPLEVEL_HEADS = (:toplevel, :block, :if, :elseif, :macrocall, :module)

# `paths` holds the path constants of the module that the walk is in: the
# included files of a module share them, and a `module` block starts its own.
function _walk_includes(expr, file, module_path, tracked, paths = Dict{Symbol, String}())
    expr isa Expr || return
    if expr.head === :call && !isempty(expr.args) && expr.args[1] === :include
        path = length(expr.args) == 2 ? _static_path(expr.args[2], file, paths) : nothing
        if path !== nothing
            included = normpath(joinpath(dirname(file), path))
            isfile(included) || error("tracked_sources: $file includes $included, " *
                                      "which does not exist")
            if isempty(module_path)
                @warn "tracked_sources: an include outside every module is not tracked" file included
            else
                push!(tracked, included => module_path)
                _walk_includes(_parse_file(included), included, module_path, tracked, paths)
            end
        else
            @warn "tracked_sources: an include of a path that the walk cannot compute is not tracked" file expr
        end
        return
    end
    if expr.head === :const
        _record_path_constant!(paths, expr.args[1], file)
        return
    end
    expr.head in _TOPLEVEL_HEADS || return
    if expr.head === :module
        name = String(expr.args[2]::Symbol)
        module_path = isempty(module_path) ? name : module_path * "." * name
        paths = Dict{Symbol, String}()
    end
    for argument in expr.args
        _walk_includes(argument, file, module_path, tracked, paths)
    end
end

const _PATH_FUNCTIONS = Dict{Symbol, Function}(:joinpath => joinpath, :normpath => normpath,
                                               :abspath => abspath, :dirname => dirname)

# The path that `x` gives in `file` without running it, or nothing.
function _static_path(x, file, paths)
    x isa AbstractString && return String(x)
    x isa Symbol && return get(paths, x, nothing)
    x isa Expr || return nothing
    if x.head === :macrocall
        x.args[1] === Symbol("@__DIR__") && return dirname(file)
        x.args[1] === Symbol("@__FILE__") && return file
        return nothing
    end
    x.head === :call && !isempty(x.args) || return nothing
    f = get(_PATH_FUNCTIONS, x.args[1], nothing)
    f === nothing && return nothing
    parts = String[]
    for argument in x.args[2:end]
        part = _static_path(argument, file, paths)
        part === nothing && return nothing
        push!(parts, part)
    end
    try
        return f(parts...)::String
    catch
        return nothing
    end
end

function _record_path_constant!(paths, assignment, file)
    assignment isa Expr && assignment.head === :(=) && assignment.args[1] isa Symbol || return
    path = _static_path(assignment.args[2], file, paths)
    path === nothing || (paths[assignment.args[1]] = path)
end

# The tracked sources of the path packages of the Manifest of `package_dir`,
# except the package itself.
function _dependency_sources(package_dir)
    package_dir = normpath(abspath(package_dir))
    manifest = nothing
    for name in ("JuliaManifest.toml", "Manifest.toml")
        isfile(joinpath(package_dir, name)) && (manifest = joinpath(package_dir, name); break)
    end
    manifest === nothing &&
        error("tracked_sources: no Manifest.toml under $package_dir; instantiate the package first")
    data = TOML.parsefile(manifest)
    haskey(data, "deps") ||
        error("tracked_sources: $manifest is not of manifest format 2; resolve it with this Julia")
    found = Pair{String, String}[]
    for (_, entries) in sort!(collect(data["deps"]); by = first)
        for entry in entries
            path = get(entry, "path", nothing)
            path isa String || continue
            dir = normpath(joinpath(package_dir, path))
            rstrip(dir, '/') == rstrip(package_dir, '/') && continue
            append!(found, tracked_sources(dir))
        end
    end
    return found
end

# `tracked`, then each pair of `added` whose file `tracked` does not hold.
function _merge_tracked(tracked, added)
    merged = Pair{String, String}[tracked...]
    roots = Dict{String, String}(abspath(file) => root for (file, root) in tracked)
    for (file, root) in added
        known = get(roots, abspath(file), nothing)
        if known === nothing
            push!(merged, file => root)
            roots[abspath(file)] = root
        elseif known != root
            error("tracked_sources: $file is included by two modules, $(repr(known)) and " *
                  "$(repr(root)); a rebuild could apply its edit to one of them only")
        end
    end
    return merged
end

# ── the status and the watch ─────────────────────────────────────────────────

"""
    print_store_status(io, app_dir) -> Bool

Print what the reactive store under `app_dir` holds — the founding, the
snapshots, the chain of overlays of the bundle, the server, the growth — and
answer whether there is one.
"""
function print_store_status(io::IO, app_dir::AbstractString)
    status = store_status(String(app_dir))
    if status === nothing
        println(io, "no reactive store under $app_dir")
        return false
    end
    mb(bytes) = string(round(bytes / 2^20; digits = 1), " MB")
    println(io, "reactive store of $app_dir")
    println(io, "  founding:   image $(mb(status.founding_size)), $(length(status.tracked)) tracked files",
            isempty(status.workload) ? "" : ", workload $(status.workload)")
    println(io, "  snapshots:  $(length(status.snapshots)) (s$(first(status.snapshots)) to s$(last(status.snapshots)))")
    println(io, "  image:      $(mb(status.image_size))",
            isempty(status.chain) ? "" : " + " * join(["$name $(mb(size))" for (name, size) in status.chain], ", "))
    println(io, "  growth:     $(round(100 * status.growth; digits = 1)) % since the founding")
    session = status.session
    if session === nothing
        println(io, "  server:     none")
    else
        println(io, "  server:     pid $(session["pid"]) ", session["alive"] ? "answers" : "does not answer",
                ", started from s$(session["base"]) on $(session["started"]), last s$(get(session, "last", session["base"]))",
                ", image $(get(session, "image", "whole"))")
    end
    return true
end

"""
    watch_app(app_dir, build; io = stdout, settle = 0.5)

Rebuild on every change of a tracked file of the store under `app_dir`,
until Ctrl-C. `build` is a function of no argument that runs the build. A
change is a new modification time of a tracked file (the store's list); the
watch waits until the files stayed still for `settle` seconds, then calls
`build` and prints the seconds. A build that fails — a refused edit, a syntax
error — prints its error, and the watch goes on. Ctrl-C stops the watch and
the compiler server.
"""
function watch_app(app_dir::AbstractString, build; io::IO = stdout, settle::Real = 0.5)
    status = store_status(String(app_dir))
    status === nothing &&
        error("watch_app: no reactive store under $app_dir; found one first")
    stamps = Dict{String,Float64}(file => (isfile(file) ? mtime(file) : 0.0) for file in status.tracked)
    # A line is flushed as it is printed: `stdout` to a file is buffered, and
    # the watch runs for hours.
    say(parts...) = (println(io, parts...); flush(io); flush(stderr))
    say("watch: $(length(stamps)) tracked files of $app_dir; Ctrl-C stops the watch and the server")
    # A script exits on Ctrl-C by default; the watch catches it to stop the
    # server, and gives the default back when it ends.
    Base.exit_on_sigint(false)
    try
        while true
            changed = _changed_files!(stamps)
            if isempty(changed)
                sleep(settle)
                continue
            end
            # An editor writes a file in steps, and a person saves several: wait
            # until nothing changed for a settle time.
            while true
                sleep(settle)
                more = _changed_files!(stamps)
                isempty(more) && break
                union!(changed, more)
            end
            say("watch: ", join(basename.(sort!(collect(changed))), ", "), " changed; rebuild")
            started = time()
            try
                build()
                say("watch: rebuilt in $(round(time() - started; digits = 1)) s")
            catch error
                error isa InterruptException && rethrow()
                say("watch: the rebuild failed after $(round(time() - started; digits = 1)) s: ",
                    sprint(showerror, error))
                say("watch: the watch goes on; fix the edit and save")
            end
        end
    catch error
        error isa InterruptException || rethrow()
        say("\nwatch: stopped")
        stop_server(String(app_dir)) && say("watch: the compiler server was stopped")
    finally
        Base.exit_on_sigint(true)
    end
    return nothing
end

# The files of `stamps` whose modification time is not the recorded one; the
# record is updated, so a file is answered once per change.
function _changed_files!(stamps::Dict{String,Float64})
    changed = Set{String}()
    for (file, stamp) in stamps
        now = isfile(file) ? mtime(file) : 0.0
        now == stamp && continue
        stamps[file] = now
        push!(changed, file)
    end
    return changed
end

# The rebuild path in the package image: a build process that rebuilds a
# store compiles none of it.
precompile(_materialize_rebuild, (String, String, Vector{Pair{String, String}}, Bool, Tuple{Int, Float64},
                                  Bool, Symbol, Symbol, Int))
precompile(tracked_sources, (String,))
precompile(_dependency_sources, (String,))
precompile(_merge_tracked, (Vector{Pair{String, String}}, Vector{Pair{String, String}}))
precompile(stop_server, (String,))
