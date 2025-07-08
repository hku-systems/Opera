# Opera: Achieving Secure and High-performance OLAP via GPU-accelerated Homomorphic Caching

## Code Structure
```
.
├── src                # Source code
├── include            # Header files
├── thirdparty         # Third-party libraries
├── CMakeLists.txt     # CMake configuration file
├── LICENSE            # License file
├── docker-compose.yml # Docker compose file
├── Dockerfile         # Dockerfile
├── cuTFHEpp           # CUDA implementation of TFHEpp library
├── test               # Tests
├── benchmark          # Benchmarks
└── README.md          # README file
```

## Requirements

- C++17/CUDA C++17
- NVIDIA Volta GPU / RTX 30 or later microarchitectures, following are the tested GPUs:
  - [x] NVIDIA A100
- CMake 3.18 or later
- CUDA 11.5 or later
- GPU with 24 GiBs or higher to run the benchmarks

## Quick Start

Simply setup the environment with docker compose:
```
docker compose up -d
```

Then, build the project in the container:
```
docker exec -it opera /bin/bash
/# cd app
/app# cmake -B ./build -DCMAKE_CUDA_ARCHITECTURES=80 && make -C build -j
```

The executable will be generated in the `build/bin` directory of the project.

## Benchmarks

The benchmark can be built with option: `-D OPERA_BUILD_BENCHMARKS=ON`,
and the executable will be located in the `build/bin` directory.

Available benchmarks:
- `tpch_q1`: TPC-H Query 1
- `tpch_q4`: TPC-H Query 4
- `tpch_q6`: TPC-H Query 6
- `tpch_q12`: TPC-H Query 12
- `tpch_q15`: TPC-H Query 15
- `tpch_q17`: TPC-H Query 17
- `tpch_q19`: TPC-H Query 19

To check the usage of the benchmark, run the executable with the `--help` option.

For example, to run the TPC-H Query 6 benchmark with the different options:
```
// Check the usage
./build/bin/tpch_q6 --help

// Run the benchmark with 16 and 32 rows
./build/bin/tpch_q6 --rows 16 32 --output output.csv

// Run the benchmark with 16 and 32 rows without fast comp
./build/bin/tpch_q6 --rows 16 32 --nofastcomp --output output.csv

// Run the benchmark with 16 and 32 rows without cache
./build/bin/tpch_q6 --rows 16 32 --nocache --output output.csv

// Run the benchmark with 16 and 32 rows without cache and check the result
./build/bin/tpch_q6 --rows 16 32 --nocache --check --output output.csv
```

## Results

The results of the benchmarks are displayed in csv format, and it can be stored in the file
specified by the `--output` option.

The following shows the examples of the result of the TPC-H Query 6 benchmark (in ms):

TPC-H Query 6 without cache:
```
./build/bin/tpch_q6 --rows 256 1024 4096 16384 --nocache --output opera-NC.csv
```

TPC-H Query 6 with cache (no fast comp):
```
./build/bin/tpch_q6 --rows 256 1024 4096 16384 --nofastcomp --output opera-base.csv
```

TPC-H Query 6 with cache (fast comp):
```
./build/bin/tpch_q6 --rows 256 1024 4096 16384 --output opera.csv
```

## Cite
If you use `Opera` for your academic work, you can cite the following paper:

```bibtex
@inproceedings{Opera,
 author      = {Hu, Qi and Chen, Wei and Shen, Tianxiang and Yao, Xin and Zhang, Nicholas and Cui, Heming and Yiu, Siu-Ming},
 booktitle   = {2025 IEEE Symposium on Security and Privacy (SP)}, 
 title       = {Opera: Achieving Secure and High-Performance OLAP with Parallelized Homomorphic Comparisons}, 
 year        = {2025},
 volume      = {},
 number      = {},
 pages       = {2360-2377},
 doi         = {10.1109/SP61157.2025.00173}
}
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Some files contain the modified code from the [Phantom](https://github.com/encryptorion-lab/phantom-fhe/tree/831931db9fb2541a2d6062205dbefcbc63bf7d8c) version licensed under [MIT License](https://github.com/encryptorion-lab/phantom-fhe/blob/831931db9fb2541a2d6062205dbefcbc63bf7d8c/MIT_LICENSE).

Some files contain the modified code from the [TFHEpp](https://github.com/virtualsecureplatform/TFHEpp),
which is licensed under the [Apache License 2.0](https://github.com/virtualsecureplatform/TFHEpp/blob/master/LICENSE).
