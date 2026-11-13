# Aqua.jl code-quality checks, run as a normal discovered test file under the parallel
# runner. `using PowerOperationsModels` / `using Test` come from the shared preamble
# (includes.jl) evaluated into this file's worker sandbox.
import Aqua

@testset "Aqua code quality" begin
    Aqua.test_undefined_exports(PowerOperationsModels)
    Aqua.test_ambiguities(PowerOperationsModels)
    # PowerMatricesCore is unregistered, so it is a direct dependency only to give its
    # `[sources]` entry effect for PowerNetworkMatrices.
    Aqua.test_stale_deps(PowerOperationsModels; ignore = [:PowerMatricesCore])
    Aqua.test_unbound_args(PowerOperationsModels)
end
