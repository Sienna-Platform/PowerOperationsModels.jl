@testset "coefficient dump round-trips and compares" begin
    model = _c_sys5_scheduled_security_constrained_model()
    mktempdir() do dir
        path_a = joinpath(dir, "a.json")
        path_b = joinpath(dir, "b.json")
        dump_post_contingency_coefficients(model, path_a)
        dump_post_contingency_coefficients(model, path_b)
        max_diff, cutoff_crossings, failures =
            compare_post_contingency_coefficients(path_a, path_b)
        @test max_diff == 0
        @test cutoff_crossings == 0
        @test isempty(failures)

        dumped = JSON.parsefile(path_a)
        matrix = IOM.get_network_matrix(_network_model(model))
        resolved = PNM.get_core(matrix).tol
        @test dumped["cutoff"]["kind"] ==
              (resolved isa PNM.RelativeCutoff ? "relative" : "absolute")
        @test dumped["cutoff"]["value"] == PNM.cutoff_value(resolved)
        @test !isempty(dumped["records"])
        @test all(r -> haskey(r, "terms"), dumped["records"])

        # One coefficient moved by 1e-6 is a failure.
        record = first(r for r in dumped["records"] if !isempty(r["terms"]))
        term = first(keys(record["terms"]))
        record["terms"][term] += 1e-6
        path_c = joinpath(dir, "c.json")
        open(path_c, "w") do io
            JSON.print(io, dumped)
        end
        max_diff, _, failures = compare_post_contingency_coefficients(path_a, path_c)
        @test max_diff > 5e-7
        @test length(failures) == 1
        @test only(failures).term == term

        # A term present on one side only passes below the cutoff and fails above it.
        threshold = cutoff_threshold(dumped["cutoff"], record["terms"])
        record["terms"][term] -= 1e-6
        record["terms"]["extra_small"] = 0.5 * threshold
        path_d = joinpath(dir, "d.json")
        open(path_d, "w") do io
            JSON.print(io, dumped)
        end
        _, cutoff_crossings, failures =
            compare_post_contingency_coefficients(path_a, path_d)
        @test cutoff_crossings == 1
        @test isempty(failures)
        record["terms"]["extra_small"] = 2 * threshold + 1.0
        open(path_d, "w") do io
            JSON.print(io, dumped)
        end
        _, _, failures = compare_post_contingency_coefficients(path_a, path_d)
        @test length(failures) == 1
    end
end

@testset "the coefficient sample is stable under adding or dropping an entry" begin
    candidates = [("o$i", "Line", "b$j", t) for i in 1:5 for j in 1:20 for t in 1:4]
    sampled = _sample_keys(candidates, 50, 1)
    @test length(sampled) == 50
    @test _sample_keys(reverse(candidates), 50, 1) == sampled
    other = first(setdiff(candidates, sampled))
    @test _sample_keys(setdiff(candidates, [other]), 50, 1) == sampled
    dropped = first(sampled)
    after = _sample_keys(setdiff(candidates, [dropped]), 50, 1)
    @test issubset(setdiff(sampled, [dropped]), after)
    @test length(setdiff(after, sampled)) == 1
end

@testset "an outage label names the outage's components" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    outage_id = _add_contingency!(sys, [line], [line])
    @test _outage_label(sys, outage_id) == "PowerSystems.Line/1"
    @test_throws ArgumentError _outage_label(sys, "not-an-outage-id")
end
