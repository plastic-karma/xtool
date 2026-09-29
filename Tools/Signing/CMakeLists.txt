cmake_minimum_required(VERSION 3.20)
project(XToolSigning LANGUAGES C CXX)
find_package(OpenSSL REQUIRED)
set(ZSIGN_SOURCE "${CMAKE_CURRENT_LIST_DIR}/../../Vendor/zsign/src")
file(GLOB ZSIGN_COMMON CONFIGURE_DEPENDS "${ZSIGN_SOURCE}/common/*.cpp")
file(GLOB ZSIGN_ZLIB CONFIGURE_DEPENDS "${ZSIGN_SOURCE}/third-party/zlib/*.c")
add_executable(xtool-sign-bundles
    sign-bundles.cpp
    "${ZSIGN_SOURCE}/archo.cpp"
    "${ZSIGN_SOURCE}/bundle.cpp"
    "${ZSIGN_SOURCE}/certcheck.cpp"
    "${ZSIGN_SOURCE}/macho.cpp"
    "${ZSIGN_SOURCE}/metadata.cpp"
    "${ZSIGN_SOURCE}/openssl.cpp"
    "${ZSIGN_SOURCE}/signing.cpp"
    ${ZSIGN_COMMON}
    ${ZSIGN_ZLIB}
    "${ZSIGN_SOURCE}/third-party/minizip/ioapi.c"
    "${ZSIGN_SOURCE}/third-party/minizip/zip.c"
    "${ZSIGN_SOURCE}/third-party/minizip/unzip.c"
)
target_compile_features(xtool-sign-bundles PRIVATE cxx_std_11)
target_include_directories(xtool-sign-bundles PRIVATE
    "${ZSIGN_SOURCE}" "${ZSIGN_SOURCE}/common" "${ZSIGN_SOURCE}/third-party/zlib")
target_link_libraries(xtool-sign-bundles PRIVATE OpenSSL::SSL OpenSSL::Crypto)
install(TARGETS xtool-sign-bundles RUNTIME DESTINATION bin)

# Phrase-model compression is also source-built, not a copied cache library.
set(LZFSE_SOURCE "${CMAKE_CURRENT_LIST_DIR}/../../Vendor/AssetKit/Sources/CLZFSE")
file(GLOB LZFSE_SOURCES CONFIGURE_DEPENDS "${LZFSE_SOURCE}/*.c")
add_library(xtool_lzfse SHARED ${LZFSE_SOURCES})
target_include_directories(xtool_lzfse PRIVATE "${LZFSE_SOURCE}" "${LZFSE_SOURCE}/include")
set_target_properties(xtool_lzfse PROPERTIES OUTPUT_NAME lzfse)
install(TARGETS xtool_lzfse LIBRARY DESTINATION lib)
