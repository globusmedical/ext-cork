cmake_minimum_required(VERSION 3.31)
project(Cork VERSION 0.0.1 LANGUAGES C CXX)

if(NOT WIN32 OR NOT CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    message(FATAL_ERROR "The initial spike requires Windows and MSVC cl.")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "The initial spike requires an x64 developer environment.")
endif()
set(CORK_EXPECTED_MSVC_VERSION "1900" CACHE STRING "Expected MSVC_VERSION for this spike")
if(NOT MSVC_VERSION STREQUAL CORK_EXPECTED_MSVC_VERSION)
    message(FATAL_ERROR "Expected MSVC ${CORK_EXPECTED_MSVC_VERSION}, got ${MSVC_VERSION}.")
endif()

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(CorkCompilerFlags)
include(CMakePackageConfigHelpers)
include(CTest)
find_package(MPIR REQUIRED)
option(CORK_BUILD_TOOLS "Build the legacy command-line tools" ON)

set(cork_sources
    src/cork.cpp
    src/util/timer.cpp
    src/util/log.cpp
    src/isct/empty3d.cpp
    src/isct/quantization.cpp
    src/file_formats/files.cpp
    src/file_formats/ifs.cpp
    src/file_formats/off.cpp
    src/isct/triangle.c
)
set_source_files_properties(src/isct/triangle.c PROPERTIES
    COMPILE_DEFINITIONS "NO_TIMER;REDUCED;CDT_ONLY;TRILIBRARY;ANSI_DECLARATORS"
)
add_library(cork_objects OBJECT ${cork_sources})
foreach(directory IN ITEMS "" util file_formats math isct mesh rawmesh accel)
    target_include_directories(cork_objects PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src/${directory}")
endforeach()
target_link_libraries(cork_objects PRIVATE MPIR::mpir)
cork_compiler_flags(cork_objects)

add_library(cork SHARED $<TARGET_OBJECTS:cork_objects> cmake/cork.def)
add_library(Cork::cork ALIAS cork)
target_link_libraries(cork PRIVATE MPIR::mpir)
target_include_directories(cork PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
    $<INSTALL_INTERFACE:include>
)
set_target_properties(cork PROPERTIES VERSION ${PROJECT_VERSION} SOVERSION 0)
cork_linker_flags(cork)

if(CORK_BUILD_TOOLS)
    add_executable(cork_cli src/main.cpp)
    target_link_libraries(cork_cli PRIVATE cork_objects MPIR::mpir)
    set_target_properties(cork_cli PROPERTIES OUTPUT_NAME cork PDB_NAME cork_cli)
    add_executable(off2obj src/off2obj.cpp)
    foreach(target IN ITEMS cork_cli off2obj)
        cork_compiler_flags(${target})
        cork_linker_flags(${target})
    endforeach()
endif()

install(TARGETS cork EXPORT CorkTargets
    RUNTIME DESTINATION bin/$<CONFIG>
    ARCHIVE DESTINATION lib/$<CONFIG>
    LIBRARY DESTINATION lib/$<CONFIG>
)
install(FILES $<TARGET_PDB_FILE:cork> DESTINATION bin/$<CONFIG>)
if(CORK_BUILD_TOOLS)
    install(TARGETS cork_cli off2obj RUNTIME DESTINATION bin/$<CONFIG>)
    install(FILES $<TARGET_PDB_FILE:cork_cli> $<TARGET_PDB_FILE:off2obj>
        DESTINATION bin/$<CONFIG>
    )
endif()
install(FILES src/cork.h DESTINATION include)
install(FILES COPYRIGHT DESTINATION share/doc/cork)
install(EXPORT CorkTargets NAMESPACE Cork:: DESTINATION lib/cmake/Cork)
configure_package_config_file(cmake/CorkConfig.cmake.in
    "${CMAKE_CURRENT_BINARY_DIR}/CorkConfig.cmake"
    INSTALL_DESTINATION lib/cmake/Cork
)
write_basic_package_version_file("${CMAKE_CURRENT_BINARY_DIR}/CorkConfigVersion.cmake"
    VERSION ${PROJECT_VERSION} COMPATIBILITY SameMajorVersion
)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/CorkConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/CorkConfigVersion.cmake"
    DESTINATION lib/cmake/Cork
)

if(BUILD_TESTING)
    add_subdirectory(tests/spike)
endif()
