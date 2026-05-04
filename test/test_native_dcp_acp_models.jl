@testset "branch_admittance primitives" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = first(PSY.get_components(PSY.Line, sys))
    a = PowerOperationsModels.branch_admittance(line)
    r, x = PSY.get_r(line), PSY.get_x(line)
    y = inv(complex(r, x))
    @test a.g ≈ real(y)
    @test a.b ≈ imag(y)
    @test a.tap == 1.0
    @test a.shift == 0.0
end

@testset "branch_flow_limits MonitoredLine" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_ml")
    ml = first(PSY.get_components(PSY.MonitoredLine, sys))
    fl = PowerOperationsModels.branch_flow_limits(ml)
    psy_fl = PSY.get_flow_limits(ml)
    @test fl.from_to == psy_fl.from_to
    @test fl.to_from == psy_fl.to_from
end
