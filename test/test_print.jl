# NOTE: The show methods in src/utils/print.jl reference PrettyTables which is not
# imported in PowerOperationsModels (only in IOM). These methods throw UndefVarError
# when invoked. This is a pre-existing bug — 0% coverage confirms they've never worked.
# Tests are omitted until the import is fixed.
