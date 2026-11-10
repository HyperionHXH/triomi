# Windows decoder and ANGLE are application-owned, hash-pinned build inputs.
# The former pub package pinned a 2023 WASAPI COM ownership defect. Never use a
# machine's unrelated mpv DLL or a floating "latest" binary as a fallback.
file(READ "${CMAKE_CURRENT_LIST_DIR}/media-dependencies.json" TRIOMI_MEDIA_PINS)

function(triomi_media_dependency name output)
  foreach(field repository release archive sha256)
    string(JSON ${field} GET "${TRIOMI_MEDIA_PINS}" ${name} ${field})
  endforeach()
  set(archive_path "${CMAKE_BINARY_DIR}/${archive}")
  if(EXISTS "${archive_path}")
    file(SHA256 "${archive_path}" actual)
    if(NOT actual STREQUAL sha256)
      message(FATAL_ERROR "Cached ${name} archive differs from the application pin: ${archive_path}")
    endif()
  else()
    file(DOWNLOAD
      "https://github.com/${repository}/releases/download/${release}/${archive}"
      "${archive_path}" EXPECTED_HASH "SHA256=${sha256}" TLS_VERIFY ON
      STATUS transfer TIMEOUT 300)
    list(GET transfer 0 code)
    if(NOT code EQUAL 0)
      message(FATAL_ERROR "Could not download pinned ${name}: ${transfer}")
    endif()
  endif()
  set(root "${CMAKE_BINARY_DIR}/triomi-media/${name}-${sha256}")
  if(NOT EXISTS "${root}/.extracted")
    file(MAKE_DIRECTORY "${root}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive_path}"
      WORKING_DIRECTORY "${root}" RESULT_VARIABLE extraction)
    if(NOT extraction EQUAL 0)
      message(FATAL_ERROR "Could not extract pinned ${name}: ${extraction}")
    endif()
    file(WRITE "${root}/.extracted" "${sha256}\n")
  endif()
  set(${output} "${root}" PARENT_SCOPE)
endfunction()

triomi_media_dependency(mpv TRIOMI_MPV_ROOT)
triomi_media_dependency(angle TRIOMI_ANGLE_ROOT)
foreach(required libmpv-2.dll libmpv.dll.a include/mpv/client.h include/mpv/render.h)
  if(NOT EXISTS "${TRIOMI_MPV_ROOT}/${required}")
    message(FATAL_ERROR "Pinned decoder is missing ${required}")
  endif()
endforeach()

# media_kit_video's native CMake contract uses these build-local paths. Populate
# them from the verified archive before configuring the rendering plugin.
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/libmpv/include")
file(COPY "${TRIOMI_MPV_ROOT}/include/mpv/" DESTINATION "${CMAKE_BINARY_DIR}/libmpv/include")
configure_file("${TRIOMI_MPV_ROOT}/libmpv.dll.a" "${CMAKE_BINARY_DIR}/libmpv/libmpv.dll.a" COPYONLY)
file(COPY "${TRIOMI_ANGLE_ROOT}/" DESTINATION "${CMAKE_BINARY_DIR}/ANGLE")
set(MEDIA_KIT_LIBS_AVAILABLE ON)
set(TRIOMI_MEDIA_BUNDLED_LIBRARIES "${TRIOMI_MPV_ROOT}/libmpv-2.dll")
foreach(dll d3dcompiler_47.dll libEGL.dll libGLESv2.dll vk_swiftshader.dll vulkan-1.dll zlib.dll)
  if(NOT EXISTS "${TRIOMI_ANGLE_ROOT}/${dll}")
    message(FATAL_ERROR "Pinned ANGLE is missing ${dll}")
  endif()
  list(APPEND TRIOMI_MEDIA_BUNDLED_LIBRARIES "${TRIOMI_ANGLE_ROOT}/${dll}")
endforeach()
