#!/usr/bin/env julia
#
# Generate lcov.info from existing .cov files for Coverage Gutters.
# Run this AFTER running tests with coverage.
#
# Usage:
#   1. Run tests with coverage:  julia --project=. -e 'using TestEnv; TestEnv.activate(); include("test/load_tests.jl"); InfrastructureOptimizationModelsTests.run_tests()'
#   2. Generate lcov:            julia --project=. -e 'using TestEnv; TestEnv.activate(); include("scripts/generate_lcov.jl")'

using CoverageTools
using Coverage

const PROJECT_ROOT = dirname(@__DIR__)

coverage = CoverageTools.process_folder(joinpath(PROJECT_ROOT, "src"))
LCOV.writefile(joinpath(PROJECT_ROOT, "lcov.info"), coverage)

@info "Wrote $(joinpath(PROJECT_ROOT, "lcov.info"))"
