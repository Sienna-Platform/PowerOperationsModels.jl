# PowerOperationsModels.jl

```@meta
CurrentModule = PowerOperationsModels
```

## Overview

`PowerOperationsModels.jl` is a [`Julia`](http://www.julialang.org) package that provides optimization models for power system components including thermal generators, renewable energy sources, energy storage, HVDC systems, and loads. It is designed to work with `InfrastructureOptimizationModels.jl` infrastructure and integrates with [`PowerSystems.jl`](https://nrel-sienna.github.io/PowerSystems.jl/stable/) for power system data structures.

## About

`PowerOperationsModels` is part of the National Laboratory of the Rockies'
[Sienna ecosystem](https://nrel-sienna.github.io/Sienna/), an open source framework for
scheduling problems and dynamic simulations for power systems. The Sienna ecosystem can be
[found on github](https://github.com/NREL-Sienna/Sienna). It contains three applications:

  - [Sienna\Data](https://github.com/NREL-Sienna/Sienna?tab=readme-ov-file#siennadata) enables
    efficient data input, analysis, and transformation
  - [Sienna\Ops](https://github.com/NREL-Sienna/Sienna?tab=readme-ov-file#siennaops) enables
    enables system scheduling simulations by formulating and solving optimization problems
  - [Sienna\Dyn](https://github.com/NREL-Sienna/Sienna?tab=readme-ov-file#siennadyn) enables
    system transient analysis including small signal stability and full system dynamic
    simulations

Each application uses multiple packages in the [`Julia`](http://www.julialang.org)
programming language.
