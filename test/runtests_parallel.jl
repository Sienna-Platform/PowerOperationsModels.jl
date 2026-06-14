using PowerOperationsModels
using ParallelTestRunner

# Each discovered file runs in its own isolated worker process. Discover ONLY the
# top-level `test_*.jl` files — `includes.jl`, the `test_utils/` helpers, and
# `test_data/` are not standalone testsets and must not be run as tests.
const TEST_DIR = @__DIR__
testsuite = Dict{String, Expr}(
    splitext(f)[1] => :(include($(joinpath(TEST_DIR, f)))) for
    f in readdir(TEST_DIR) if startswith(f, "test_") && endswith(f, ".jl")
)

# Shared preamble (package imports, `test_utils`, consts) evaluated into each test's
# sandbox module before the test file runs.
const INIT_CODE = :(include($(joinpath(TEST_DIR, "includes.jl"))))

# Worker processes share the on-disk PowerSystemCaseBuilder serialized-system store
# (HDF5). HDF5's default file locking rejects concurrent opens across processes, so
# disable it for the test workers (read-only access to a pre-serialized store is safe).
const WORKER_ENV = ["HDF5_USE_FILE_LOCKING" => "FALSE", "RUNNING_SIENNA_TESTS" => "true"]

runtests(PowerOperationsModels, ARGS; testsuite, init_code = INIT_CODE, env = WORKER_ENV)
