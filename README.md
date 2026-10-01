# PowerOperationsModels.jl

| **Documentation** | **Build Status** |
|:---:|:---:|
| [![][docs-sienna-img]][docs-sienna-url] [![][docs-stable-img]][docs-stable-url] [![][docs-dev-img]][docs-dev-url] | [![Main - CI](https://github.com/Sienna-Platform/PowerOperationsModels.jl/actions/workflows/main-tests.yml/badge.svg)](https://github.com/Sienna-Platform/PowerOperationsModels.jl/actions/workflows/main-tests.yml) [![codecov](https://codecov.io/gh/Sienna-Platform/PowerOperationsModels.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Sienna-Platform/PowerOperationsModels.jl) [<img src="https://img.shields.io/badge/slack-@Sienna/PowerOperationsModels-sienna.svg?logo=slack">](https://join.slack.com/t/core-sienna/shared_invite/zt-glam9vdu-o8A9TwZTZqqNTKHa7q3BpQ) [![PowerOperationsModels.jl Downloads](https://shields.io/endpoint?url=https://pkgs.genieframework.com/api/v1/badge/PowerOperationsModels)](https://pkgs.genieframework.com?packages=PowerOperationsModels) |

[docs-sienna-img]: https://img.shields.io/badge/Central_Sienna_docs-blue.svg
[docs-sienna-url]: https://sienna-platform.github.io/Sienna/SiennaDocs/docs/build/index/
[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://sienna-platform.github.io/PowerOperationsModels.jl/stable/
[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://sienna-platform.github.io/PowerOperationsModels.jl/dev/

`PowerOperationsModels.jl` is a Julia package that contains optimization models for power system components. It is part of the Sienna Platform ecosystem for power system modeling and simulation.

## Features

- Device-specific optimization models (thermal generators, renewables, storage, HVDC, loads, etc.)
- Integration with PowerSystems.jl for power system data structures
- Native network formulations (DCP, ACP, ACR, IVR, LPACC, NFA, DCPLL) implemented directly in POM.
- Designed to work with InfrastructureOptimizationModels.jl infrastructure

## Development

Contributions to the development and enhancement of PowerOperationsModels.jl are welcome. Please see [CONTRIBUTING.md](https://github.com/Sienna-Platform/PowerOperationsModels.jl/blob/main/CONTRIBUTING.md) for code contribution guidelines.

## License

PowerOperationsModels.jl is released under a BSD [license](https://github.com/Sienna-Platform/PowerOperationsModels.jl/blob/main/LICENSE). PowerOperationsModels.jl has been developed as part of the Sienna ecosystem at the U.S. Department of Energy's National Laboratory of the Rockies ([NLR](https://www.nlr.gov/)), formerly known as NREL.
