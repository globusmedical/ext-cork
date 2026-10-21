foreach(language IN ITEMS C CXX)
    foreach(configuration IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
        foreach(flag IN ITEMS /DNDEBUG /Ob0 /Ob1 /Ob2 /Od /O1 /O2 /RTC1 /Zi /ZI /Z7)
            string(REPLACE "${flag}" "" CMAKE_${language}_FLAGS_${configuration}
                "${CMAKE_${language}_FLAGS_${configuration}}"
            )
        endforeach()
    endforeach()
endforeach()

function(cork_compiler_flags target)
    target_compile_features(${target} PRIVATE cxx_std_11)
    set_target_properties(${target} PROPERTIES
        CXX_EXTENSIONS OFF
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL"
    )
    target_compile_definitions(${target} PRIVATE _USE_MATH_DEFINES NOMINMAX)
    target_compile_options(${target} PRIVATE /W3 /Zi
        "$<$<CONFIG:Debug>:/Od;/RTC1>"
        "$<$<NOT:$<CONFIG:Debug>>:/O2;/Oi;/Gy;/GL>"
    )
endfunction()

function(cork_linker_flags target)
    target_link_options(${target} PRIVATE /DEBUG /INCREMENTAL:NO
        "$<$<NOT:$<CONFIG:Debug>>:/LTCG;/OPT:REF;/OPT:ICF>"
    )
endfunction()
