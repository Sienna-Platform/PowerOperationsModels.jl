import PrecompileTools

PrecompileTools.@setup_workload begin
    PrecompileTools.@compile_workload begin
        template = PowerOperationsProblemTemplate()
        set_device_model!(template, PSY.ThermalStandard, ThermalDispatchNoMin)
        set_device_model!(template, PSY.PowerLoad, StaticPowerLoad)
        set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
        set_device_model!(template, PSY.TModelHVDCLine, DCLossyLine)
    end
end
