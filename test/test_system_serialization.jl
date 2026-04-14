@testset "System HDF5 serialization in build" begin
    @testset "DecisionModel build with store_system_in_results=true" begin
        template = get_thermal_dispatch_template_network()
        c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
        model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
        output_dir = mktempdir(; cleanup = true)
        @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
        hdf5_path = joinpath(output_dir, IOM.HDF_MODEL_STORE_FILENAME)
        @test isfile(hdf5_path)
    end

    @testset "DecisionModel build with store_system_in_results=false" begin
        template = get_thermal_dispatch_template_network()
        c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
        model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
        output_dir = mktempdir(; cleanup = true)
        @test build!(
            model;
            output_dir = output_dir,
            store_system_in_results = false,
        ) == IOM.ModelBuildStatus.BUILT
        hdf5_path = joinpath(output_dir, IOM.HDF_MODEL_STORE_FILENAME)
        @test !isfile(hdf5_path)
    end
end
