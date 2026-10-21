cmake_minimum_required(VERSION 3.31)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(CorkSpikeConsumer LANGUAGES CXX)
    enable_testing()
    find_package(Cork CONFIG REQUIRED)
endif()

add_executable(cork_spike_consumer consumer.cpp)
target_link_libraries(cork_spike_consumer PRIVATE Cork::cork)
target_compile_features(cork_spike_consumer PRIVATE cxx_std_11)
set_target_properties(cork_spike_consumer PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL"
)
add_test(NAME spike_consumer COMMAND cork_spike_consumer)
set_tests_properties(spike_consumer PROPERTIES TIMEOUT 30)
