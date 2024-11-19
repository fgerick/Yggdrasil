# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

YGGDRASILPATH = joinpath(@__DIR__, "..", "..")

include(joinpath(YGGDRASILPATH, "platforms", "microarchitectures.jl"))
include(joinpath(YGGDRASILPATH, "platforms", "cuda.jl"))

name = "SHTns"
version = v"3.7"
version_string = version.patch == 0 ? string(version.major)*"."*string(version.minor) : string(version)

# Collection of sources required to complete build (note to self: use `sha256sum` to generate the checksum from tarball) 
sources = [
    ArchiveSource("https://gricad-gitlab.univ-grenoble-alpes.fr/schaeffn/shtns/-/archive/v$(version_string)/shtns-v$(version_string).tar.gz",
                  "6c727ccc4d15d3170c3e20ad2b8a721c8b1fd838b1944c7d7e515a4fce43f75c")
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir/shtns*/
export CFLAGS="-fPIC -O3" #only -fPIC produces slow code on linux x86 and MacOS x86 (maybe others)

#remove lfftw3_omp library references, as FFTW_jll does not provide it
sed -i -e 's/lfftw3_omp/lfftw3/' configure

#remove cuda arch specification and test
sed -i -e '/any compatible gpu/d' configure 

configure_args="--prefix=${prefix} --host=${target} --enable-openmp --enable-kernel-compiler=cc "
link_flags="-lfftw3 "

if [[ $bb_full_target == *cuda* ]]; then
    configure_args+="--enable-cuda --enable-shared"
    export CUDA_PATH="$prefix/cuda"
    export PATH=$CUDA_PATH/bin:$PATH
    export LDFLAGS="$LDFLAGS -L$CUDA_PATH/lib -L$CUDA_PATH/lib/stubs"

    ./configure $configure_args
    make -j${nproc} 

    mv *.so ${libdir}/libshtns.${dlext}
else
   ./configure $configure_args
    make -j${nproc} 
    rm *.a
    mkdir -p ${libdir}
    cc -fopenmp -shared $link_flags -o "${libdir}/libshtns.${dlext}" *.o 
fi

install_license LICENSE
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line

# Expand for microarchitectures on x86_64 (library doesn't have CPU dispatching)
cpu_platforms = expand_microarchitectures(supported_platforms(), ["x86_64", "avx", "avx2", "avx512"])

augment_platform_block = """
    $(MicroArchitectures.augment)
    function augment_platform!(platform::Platform)
        # We augment only x86_64
        @static if Sys.ARCH === :x86_64
            augment_microarchitecture!(platform)
        else
            platform
        end
    end
    """

cuda_platforms = expand_microarchitectures(CUDA.supported_platforms(), ["x86_64", "avx", "avx2", "avx512"])

filter!(p -> arch(p) != "aarch64", cuda_platforms) #doesn't work

platforms = [cpu_platforms; cuda_platforms]

# The products that we will ensure are always built
products = [
    LibraryProduct("libshtns", :LibSHTns)
]

# Dependencies that must be installed before this package can be built
dependencies = [
    Dependency(PackageSpec(name="FFTW_jll")),
    # For OpenMP we use libomp from `LLVMOpenMP_jll` where we use LLVM as compiler (BSD
    # systems), and libgomp from `CompilerSupportLibraries_jll` everywhere else. 
    Dependency(PackageSpec(name="CompilerSupportLibraries_jll"); platforms=filter(!Sys.isbsd, platforms)),
    Dependency(PackageSpec(name="LLVMOpenMP_jll"); platforms=filter(Sys.isbsd, platforms)),
]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, cpu_platforms, products, dependencies;
                julia_compat = "1.6",
                preferred_gcc_version = v"10",
                augment_platform_block)

for platform in cuda_platforms
    build_tarballs(ARGS, name, version, sources, script, [platform], products, [dependencies; CUDA.required_dependencies(platform)];
                julia_compat = "1.6",
                preferred_gcc_version = v"10",
                augment_platform_block = CUDA.augment*augment_platform_block)
end
