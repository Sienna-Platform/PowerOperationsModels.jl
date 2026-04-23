using Documenter
import DataStructures: OrderedDict
using PowerOperationsModels
using DocumenterInterLinks

links = InterLinks(
    "PowerSystems" => "https://sienna-platform.github.io/PowerSystems.jl/stable/",
    "PowerSimulations" => "https://sienna-platform.github.io/PowerSimulations.jl/stable/",
)

include(joinpath(@__DIR__, "make_tutorials.jl"))
make_tutorials()

pages = OrderedDict(
    "Welcome Page" => "index.md",
    # "Tutorials" => Any["stub" => "tutorials/generated_stub.md"],
    # "How to..." => Any["stub" => "how_to_guides/stub.md"],
    # "Explanation" => Any["stub" => "explanation/stub.md"],
    "Reference" => Any[
        "Developers" => ["Developer Guidelines" => "reference/developer_guidelines.md",
        "Internals" => "reference/internal.md"],
        "Public API" => "reference/public.md",
    ],
)

makedocs(
    modules = [PowerOperationsModels],
    format = Documenter.HTML(
        prettyurls = haskey(ENV, "GITHUB_ACTIONS"),
        size_threshold = nothing,),
    sitename = "github.com/Sienna-Platform/PowerOperationsModels.jl",
    authors = "Sienna-Platform",
    pages = Any[p for p in pages],
    draft = false,
    plugins = [links],
)

deploydocs(
    repo="github.com/Sienna-Platform/PowerOperationsModels.jl",
    target="build",
    branch="gh-pages",
    devbranch="main",
    devurl="dev",
    push_preview=true,
    versions=["stable" => "v^", "v#.#"],
)
