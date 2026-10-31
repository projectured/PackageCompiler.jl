# [Reactive builds](@id reactive)

A reactive build rebuilds an app in about a second after an edit, instead of
the minutes of `create_app`. It needs the reactive Julia (the
`reactive-compiler` branch of the Julia tree in this workspace), whose
system image carries the stdlib `ReactiveCompiler` and whose `julia` takes
`--reactive-server=<socket>`. On a stock Julia a rebuild refuses.

## The store

`materialize_app(package_dir, app_dir; workload, kwargs...)` founds a
*store* under `app_dir/reactive-store` on its first call: a whole build
through `create_app` in the reactive image format, the sources it tracks
(by default the files that the package's root file includes, see
[`tracked_sources`](@ref)), the trace of `workload` (a script that runs the
program; the founding traces it in a throwaway process, no build executes
the program), and one snapshot per build. Every later call is a rebuild: it
reads the tracked sources from disk, sends the changes to the compiler
server of the store — a process that keeps the image in memory, started
with `julia --reactive-server` — and saves the image: an overlay beside the
base by default, the code of the edits since the founding and no more. An
edit that only a founding can apply (a module option, a new dependency, a
type that an untracked file names) is refused with the reason, and the
store stays as it was.

The options of a rebuild are keywords, each with an environment variable as
its default:

| Keyword | Variable | Values |
| --- | --- | --- |
| `server` | `JULIA_REACTIVE_SERVER` | `true` (the server), `false` (a child process) |
| `image` | `JULIA_REACTIVE_IMAGE_WRITE` | `:overlay`, `:pages`, `:whole` |
| `delta_opt` | `JULIA_REACTIVE_DELTA_OPT` | the `-O` level of the edit's code, 0 to 3; -1 the build's |
| `trim` | `JULIA_REACTIVE_TRIM` | `:off`, `:on`, `:once`: the trimmed product beside the bundle |
| `founding` | `JULIA_REACTIVE_FOUNDING` | `true` founds the store again now |
| `compact` | `JULIA_REACTIVE_COMPACT` | `(saves, growth)`: found again after that many saves or that growth |

`create_app` takes `reactive = :auto`: a store under `app_dir` makes the
build a rebuild through `materialize_app`; `true` founds one when there is
none; `false` builds plain although a store exists.

Beside the build: [`store_status`](@ref) and [`print_store_status`](@ref)
answer what a store holds, [`stop_server`](@ref) stops its server,
[`watch_app`](@ref) rebuilds on every change of a tracked file, and
[`refresh_trace`](@ref) runs the workload from the current binary and adds
what it compiles to the trace, for an edit that calls new code.

## The command line

```
julia -m PackageCompiler build <app_dir> [--package=<dir>] [options]
julia -m PackageCompiler status <app_dir>
julia -m PackageCompiler stop <app_dir>
julia -m PackageCompiler watch <app_dir> [--package=<dir>] [options]
```

`build` founds the store when `app_dir` holds none and rebuilds otherwise.
A founding takes `--package=<dir>` (the package to build), and:

| Option | What it sets |
| --- | --- |
| `--workload=<file>` | the script the founding traces |
| `--tracked=<file>=<Module>,...` | the tracked files, instead of the includes of the root file |
| `--executable=<name>=<main>` | the launcher and its entry point (default: the package's name and `julia_main`) |
| `--optimization=<n>`, `--debug-info=<n>`, `--cpu-target=<target>` | the image: `-O` (3), `-g` (1), the processor (`native`) |

A rebuild, and a founding too, take the keywords of `materialize_app` as
options: `--no-server`, `--image=<mode>`, `--delta-opt=<n>`, `--found`,
`--compact=<n>,<f>`, `--trim`.

`status` prints the store — the founding, the snapshots, the chain of
overlays, the server, the growth — and exits 1 without one. `stop` stops
the compiler server. `watch` builds once, then rebuilds on every change of
a tracked file until Ctrl-C, which stops the watch and the server; wait for
its line `watch: N tracked files` before Ctrl-C, because the first build
may be a founding, and a founding interrupted is a founding lost.

A founding from a shell alone:

```
julia --project=<an environment with PackageCompiler> -m PackageCompiler \
    build /tmp/myapp --package=/path/to/MyApp --workload=/path/to/workload.jl
/tmp/myapp/bin/MyApp
# edit the sources of MyApp
julia --project=... -m PackageCompiler build /tmp/myapp        # about a second
```

The entry point of the app, `julia_main`, must be `Base.@ccallable` for a
trimmed product (`--trim`): the trimmer walks the program from the
C-callable entry points, and the build refuses a trimmed image without one.

## What to know

- An overlay server starts from the founding image, and its first apply
  takes every change since the founding. Each save writes the whole chain:
  one overlay, which replaces the one before. A new server costs the parse
  and the compile of all these changes again, so the growth bound of
  `compact` comes only from the edits themselves.
- A founding builds into `<app_dir>.founding` beside the app and swaps it
  in at the end: a build killed on the way leaves the old app and its store
  as they were, and the next founding clears the staging directory.
- A store founded before a rebuild of the reactive Julia runs the harness
  of the image it was founded on; found it again after a `make` of the
  Julia tree.
- The design, the numbers and the gates are in
  `contrib/reactive-compiler/` of the Julia tree: `doc/architecture.md` and
  `plan/`.

```@docs
materialize_app
refresh_trace
store_status
print_store_status
stop_server
watch_app
tracked_sources
```
